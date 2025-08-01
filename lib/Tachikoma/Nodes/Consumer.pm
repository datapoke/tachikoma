#!/usr/bin/perl
# ----------------------------------------------------------------------
# Tachikoma::Nodes::Consumer
# ----------------------------------------------------------------------
#
#   - Fetches messages from Partitions
#

package Tachikoma::Nodes::Consumer;
use strict;
use warnings;
use Tachikoma::Nodes::Timer;
use Tachikoma::Message qw(
    TYPE FROM TO ID PAYLOAD
    TM_REQUEST TM_STORABLE TM_PERSIST TM_RESPONSE TM_ERROR TM_EOF
    VECTOR_SIZE
);
use Getopt::Long qw( GetOptionsFromString );
use Time::HiRes  qw( usleep );
use parent       qw( Tachikoma::Nodes::Timer );

use version; our $VERSION = qv('v2.0.256');

my $ASYNC_INTERVAL  = 15;           # sanity check for new messages this often
my $POLL_INTERVAL   = 0.1;          # sync check for new messages this often
my $DEFAULT_TIMEOUT = 900;          # default message timeout
my $EXPIRE_INTERVAL = 15;           # check message timeouts
my $COMMIT_INTERVAL = 60;           # commit offsets
my $HUB_TIMEOUT     = 300;          # timeout waiting for hub
my $CACHE_TYPE      = 'snapshot';   # save complete state

sub new {
    my $class      = shift;
    my $self       = $class->SUPER::new;
    my $new_buffer = q();
    $self->{partition}       = shift;
    $self->{offsetlog}       = shift;
    $self->{broker_id}       = undef;
    $self->{partition_id}    = undef;
    $self->{offset}          = undef;
    $self->{next_offset}     = undef;
    $self->{buffer}          = \$new_buffer;
    $self->{async_interval}  = $ASYNC_INTERVAL;
    $self->{timeout}         = $DEFAULT_TIMEOUT;
    $self->{hub_timeout}     = $HUB_TIMEOUT;
    $self->{last_receive}    = Time::HiRes::time;
    $self->{cache}           = undef;
    $self->{cache_type}      = $CACHE_TYPE;
    $self->{last_cache_size} = undef;
    $self->{auto_commit}     = $self->{offsetlog} ? $COMMIT_INTERVAL : undef;
    $self->{default_offset}  = 'end';
    $self->{last_commit}     = 0;
    $self->{last_commit_offset}      = -1;
    $self->{expecting}               = undef;
    $self->{saved_offset}            = undef;
    $self->{inflight}                = [];
    $self->{last_expire}             = $Tachikoma::Now;
    $self->{msg_unanswered}          = 0;
    $self->{max_unanswered}          = 1;
    $self->{status}                  = $self->{offsetlog} ? 'INIT' : 'ACTIVE';
    $self->{registrations}->{ACTIVE} = {};
    $self->{registrations}->{READY}  = {};

    # sync support
    if ( length $self->{partition} ) {
        $self->{host}          = 'localhost';
        $self->{port}          = 4230;
        $self->{target}        = undef;
        $self->{poll_interval} = $POLL_INTERVAL;
        $self->{eos}           = undef;
        $self->{sync_error}    = undef;
    }
    bless $self, $class;
    return $self;
}

sub help {
    my $self = shift;
    return <<'EOF';
make_node Consumer <node name> --partition=<path>            \
                               --offsetlog=<path>            \
                               --max_unanswered=<int>        \
                               --timeout=<seconds>           \
                               --hub_timeout=<seconds>       \
                               --cache_type=<string>         \
                               --auto_commit=<seconds>       \
                               --default_offset=<int|string>
    # valid cache types: window, snapshot
    # valid offsets: start (0), recent (-2), end (-1)
EOF
}

sub arguments {
    my $self = shift;
    if (@_) {
        my $arguments = shift;
        my ( $partition, $offsetlog, $max_unanswered, $timeout, $hub_timeout,
            $cache_type, $auto_commit, $default_offset, );
        my ( $r, $argv ) = GetOptionsFromString(
            $arguments,
            'partition=s'      => \$partition,
            'offsetlog=s'      => \$offsetlog,
            'max_unanswered=i' => \$max_unanswered,
            'timeout=i'        => \$timeout,
            'hub_timeout=i'    => \$hub_timeout,
            'cache_type=s'     => \$cache_type,
            'auto_commit=i'    => \$auto_commit,
            'default_offset=s' => \$default_offset,
        );
        $partition //= shift @{$argv};
        die "ERROR: bad arguments for Consumer\n"
            if ( not $r or not $partition );
        my $new_buffer = q();
        $self->{arguments}          = $arguments;
        $self->{partition}          = $partition;
        $self->{offsetlog}          = $offsetlog;
        $self->{offset}             = undef;
        $self->{next_offset}        = undef;
        $self->{buffer}             = \$new_buffer;
        $self->{msg_unanswered}     = 0;
        $self->{max_unanswered}     = $max_unanswered // 1;
        $self->{timeout}            = $timeout     || $DEFAULT_TIMEOUT;
        $self->{hub_timeout}        = $hub_timeout || $HUB_TIMEOUT;
        $self->{last_receive}       = $Tachikoma::Now;
        $self->{cache_type}         = $cache_type // $CACHE_TYPE;
        $self->{last_cache_size}    = undef;
        $self->{auto_commit}        = $auto_commit // $COMMIT_INTERVAL;
        $self->{auto_commit}        = undef if ( not $offsetlog );
        $self->{default_offset}     = $default_offset // 'end';
        $self->{last_commit}        = 0;
        $self->{last_commit_offset} = -1;
        $self->{expecting}          = undef;
        $self->{saved_offset}       = undef;
        $self->{inflight}           = [];
        $self->{last_expire}        = $Tachikoma::Now;
        $self->{status}             = $offsetlog ? 'INIT' : 'ACTIVE';
        $self->{set_state}          = {};
    }
    return $self->{arguments};
}

sub fill {
    my $self    = shift;
    my $message = shift;
    if ( $message->[TYPE] == TM_REQUEST ) {
        $self->set_timer(0);
    }
    elsif ( $message->[TYPE] == ( TM_PERSIST | TM_RESPONSE ) ) {
        $self->handle_response($message);
    }
    elsif ( $message->[TYPE] & TM_ERROR ) {
        $self->handle_error($message);
    }
    else {
        my $offset = $message->[ID];
        if ( not $self->{expecting} or not defined $offset ) {
            $self->drop_message( $message, 'unexpected message' )
                if ( not $message->[TYPE] & TM_EOF );
            return;
        }
        if (    $self->{next_offset} > 0
            and $offset != $self->{next_offset} )
        {
            $self->stderr( 'WARNING: skipping from ',
                $self->{next_offset}, ' to ', $offset );
            $self->next_offset(undef);
        }
        $self->{offset} //= $offset;
        if ( $message->[TYPE] & TM_EOF ) {
            $self->handle_EOF($message);
        }
        else {
            $self->{next_offset} = $offset + length $message->[PAYLOAD];
            ${ $self->{buffer} } .= $message->[PAYLOAD];
            $self->set_timer(0)
                if (
                $self->{timer_interval}
                and ( not $self->{max_unanswered}
                    or $self->{msg_unanswered} < $self->{max_unanswered} )
                );
        }
        $self->{last_receive} = $Tachikoma::Now;
        $self->{expecting}    = undef;
    }
    return;
}

sub handle_response {
    my $self           = shift;
    my $message        = shift;
    my $msg_unanswered = $self->{msg_unanswered};
    my $offset         = $message->[ID];
    if ( $message->[PAYLOAD] eq 'answer' ) {
        $self->remove_node if ( defined $self->partition_id );
        return;
    }
    return $self->drop_message( $message, 'unexpected payload' )
        if ( $message->[PAYLOAD] ne 'cancel' );
    return $self->drop_message( $message, 'unexpected response' )
        if ( $msg_unanswered < 1 );

    if ( length $offset ) {
        my $lowest = $self->{inflight}->[0];
        if ( $lowest and $lowest->[0] == $offset ) {
            shift @{ $self->{inflight} };
        }
        elsif ( not defined $self->cancel_offset($offset) ) {
            return $self->print_less_often(
                'WARNING: unexpected response offset ',
                "$offset from ",
                $message->[FROM]
            );
        }
    }
    $msg_unanswered--;
    $self->{last_receive} = $Tachikoma::Now;
    $self->set_timer(0)
        if ($self->{timer_interval}
        and $msg_unanswered < $self->{max_unanswered} );
    $self->{msg_unanswered} = $msg_unanswered;
    return;
}

sub cancel_offset {
    my $self   = shift;
    my $offset = shift;
    my $match  = undef;
    ## no critic (ProhibitCStyleForLoops)
    for ( my $i = 0; $i < @{ $self->{inflight} }; $i++ ) {
        if ( $self->{inflight}->[$i]->[0] == $offset ) {
            $match = $i;
            last;
        }
    }
    splice @{ $self->{inflight} }, $match, 1 if ( defined $match );
    return $match;
}

sub handle_error {
    my $self    = shift;
    my $message = shift;
    $self->stderr( $message->[PAYLOAD] )
        if ( $message->[PAYLOAD] ne "NOT_AVAILABLE\n" );
    $self->restart;
    return;
}

sub handle_EOF {
    my $self    = shift;
    my $message = shift;
    my $offset  = $message->[ID];
    if ( $self->{status} eq 'INIT' ) {
        $self->{status} = 'ACTIVE';
        $self->load_cache_complete;
        $self->next_offset( $self->{saved_offset} );
        $self->set_timer(0) if ( $self->{timer_interval} );
        $self->set_state('ACTIVE')
            if ( not $self->{set_state}->{ACTIVE} );
    }
    else {
        $self->{next_offset} = $offset;
        $self->set_state('READY')
            if ( not $self->{set_state}->{READY} );
    }
    return;
}

sub fire {
    my $self = shift;
    $self->stderr( 'DEBUG: FIRE ', $self->{timer_interval}, 'ms' )
        if ( $self->{debug_state} and $self->{debug_state} >= 3 );
    if ( not $self->{msg_unanswered}
        and $Tachikoma::Now - $self->{last_receive} > $self->{hub_timeout} )
    {
        $self->print_less_often(
            'WARNING: timeout waiting for partition, trying again');
        $self->restart;
        return;
    }
    if (    $self->{status} eq 'ACTIVE'
        and $Tachikoma::Now - $self->{last_expire} >= $EXPIRE_INTERVAL )
    {
        $self->expire_messages or return;
    }
    if ( not $self->{timer_interval}
        or $self->{timer_interval} != $self->{async_interval} * 1000 )
    {
        if ( defined $self->{partition_id} ) {
            $self->stop_timer;
            $self->{timer_interval} = $self->{async_interval} * 1000;
        }
        else {
            $self->set_timer( $self->{async_interval} * 1000 );
        }
    }
    if ( length ${ $self->{buffer} } ) {
        if ( $self->{status} eq 'INIT' ) {
            $self->drain_buffer_init;
        }
        elsif ( not $self->{max_unanswered} ) {
            $self->drain_buffer_normal;
        }
        elsif ( $self->{msg_unanswered} < $self->{max_unanswered} ) {
            $self->drain_buffer_persist;
        }
    }
    if ((   not $self->{max_unanswered}
            or $self->{msg_unanswered} < $self->{max_unanswered}
        )
        and not $self->{expecting}
        )
    {
        $self->get_batch;
    }
    return;
}

sub drain_buffer_init {
    my $self   = shift;
    my $offset = $self->{offset};
    my $buffer = $self->{buffer};
    my $got    = length ${$buffer};

    # XXX:M
    # my $size =
    #     $got > VECTOR_SIZE
    #     ? VECTOR_SIZE + unpack 'N', ${$buffer}
    #     : 0;
    my $size = $got > VECTOR_SIZE ? unpack 'N', ${$buffer} : 0;
    while ( defined $self->{offset} and $got >= $size and $size > 0 ) {
        my $message =
            Tachikoma::Message->unpacked( \substr ${$buffer}, 0, $size, q() );
        if ( $message->[TYPE] & TM_STORABLE ) {
            $self->load_cache( $message->payload );
        }
        else {
            $self->print_less_often( 'WARNING: unexpected ',
                $message->type_as_string, ' in cache' );
        }
        $offset += $size;
        $got    -= $size;

        # XXX:M
        # $size =
        #     $got > VECTOR_SIZE
        #     ? VECTOR_SIZE + unpack 'N', ${$buffer}
        #     : 0;
        $size = $got > VECTOR_SIZE ? unpack 'N', ${$buffer} : 0;
    }
    if ( defined $self->{offset} and $self->{offset} != $offset ) {
        $self->{last_receive} = $Tachikoma::Now;
        $self->{offset}       = $offset;
    }
    return;
}

sub drain_buffer_normal {
    my $self   = shift;
    my $offset = $self->{offset};
    my $buffer = $self->{buffer};
    my $i      = $self->{partition_id};
    my $got    = length ${$buffer};

    # XXX:M
    my $size = $got > VECTOR_SIZE ? unpack 'N', ${$buffer} : 0;
    while ( defined $self->{offset} and $got >= $size and $size > 0 ) {
        my $message =
            Tachikoma::Message->unpacked( \substr ${$buffer}, 0, $size, q() );
        $message->[FROM] =
            defined $i
            ? join q(/), $self->{name}, $i
            : $self->{name};
        $message->[TO] = $self->{owner};
        $message->[ID] = $offset;
        $message->[TYPE] ^= TM_PERSIST
            if ( $message->[TYPE] & TM_PERSIST );
        $self->{counter}++;
        $self->{sink}->fill($message);
        $offset += $size;
        $got    -= $size;

        # XXX:M
        $size = $got > VECTOR_SIZE ? unpack 'N', ${$buffer} : 0;
    }
    if ( defined $self->{offset} and $self->{offset} != $offset ) {
        $self->{last_receive} = $Tachikoma::Now;
        $self->{offset}       = $offset;
    }
    return;
}

sub drain_buffer_persist {
    my $self   = shift;
    my $offset = $self->{offset};
    my $buffer = $self->{buffer};
    my $i      = $self->{partition_id};
    my $got    = length ${$buffer};

    # XXX:M
    my $size = $got > VECTOR_SIZE ? unpack 'N', ${$buffer} : 0;
    while ( defined $self->{offset} and $got >= $size and $size > 0 ) {
        my $message =
            Tachikoma::Message->unpacked( \substr ${$buffer}, 0, $size, q() );
        $message->[FROM] =
            defined $i
            ? join q(/), $self->{name}, $i
            : $self->{name};
        $message->[TO] = $self->{owner};
        $message->[ID] = $offset;
        if ( $message->[TYPE] & TM_EOF ) {
            $message->[TYPE] ^= TM_PERSIST
                if ( $message->[TYPE] & TM_PERSIST );
        }
        else {
            $message->[TYPE] |= TM_PERSIST;
            push @{ $self->{inflight} }, [ $offset => $Tachikoma::Now ];
            $self->{msg_unanswered}++;
        }
        $self->{counter}++;
        $self->{sink}->fill($message);
        $offset += $size;
        $got    -= $size;
        last if ( $self->{msg_unanswered} >= $self->{max_unanswered} );

        # XXX:M
        $size = $got > VECTOR_SIZE ? unpack 'N', ${$buffer} : 0;
    }
    if ( defined $self->{offset} and $self->{offset} != $offset ) {
        $self->{last_receive} = $Tachikoma::Now;
        $self->{offset}       = $offset;
    }
    return;
}

sub get_batch {
    my $self   = shift;
    my $offset = $self->{next_offset};
    return if ( not $self->{name} );
    if ( not defined $offset ) {
        if ( $self->{status} eq 'INIT' ) {
            if ( $self->{cache_type} eq 'window' ) {
                $offset = 0;
            }
            else {
                $offset = -2;
            }
        }
        elsif ( $self->default_offset eq 'start' ) {
            $offset = 0;
        }
        elsif ( $self->default_offset eq 'recent' ) {
            $offset = -2;
        }
        else {
            $offset = -1;
        }
        $self->next_offset($offset);
    }
    elsif ( $self->{status} eq 'ACTIVE'
        and $self->{saved_offset}
        and $self->{next_offset} == $self->{saved_offset} )
    {
        $self->{next_offset}  = 0;
        $self->{saved_offset} = undef;
    }
    my $message = Tachikoma::Message->new;
    $message->[TYPE] = TM_REQUEST;
    $message->[FROM] = $self->{name};
    $message->[TO] =
          $self->{status} eq 'INIT'
        ? $self->{offsetlog}
        : $self->{partition};
    $message->[PAYLOAD] = "GET $offset\n";
    $self->{expecting} = 1;
    $self->stderr( 'DEBUG: ' . $message->[PAYLOAD] )
        if ( $self->{debug_state} and $self->{debug_state} >= 2 );
    Tachikoma->nodes->{_router}->fill($message);
    return;
}

sub expire_messages {
    my $self      = shift;
    my $lowest    = $self->{inflight}->[0];
    my $timestamp = $lowest ? $lowest->[1] : undef;
    my $offset    = $lowest ? $lowest->[0] : $self->{offset};
    my $retry     = undef;
    return 1 if ( not defined $offset );
    if ( defined $timestamp
        and $Tachikoma::Now - $timestamp > $self->{timeout} )
    {
        $self->stderr('WARNING: timeout waiting for response, trying again');
        $self->restart;
        $self->next_offset($offset)
            if ( not defined $self->partition_id and not $self->offsetlog );
        $retry = 1;
    }
    elsif ( $self->{auto_commit}
        and $self->{last_commit}
        and $Tachikoma::Now - $self->{last_commit} >= $self->{auto_commit}
        and $offset != $self->{last_commit_offset} )
    {
        $self->commit_offset;
    }
    $self->{last_expire} = $Tachikoma::Now;
    return not $retry;
}

sub commit_offset {
    my $self      = shift;
    my $timestamp = shift;
    my $cache     = shift;
    my $lowest    = $self->{inflight}->[0];
    my $offset    = $lowest ? $lowest->[0] : $self->{offset};
    my $stored    = {
        timestamp  => $timestamp // $Tachikoma::Now,
        offset     => $offset,
        cache_type => $self->{cache_type},
        cache      => $cache,
    };
    return if ( not $self->{sink} );
    $self->stderr( 'DEBUG: COMMIT_OFFSET ', $offset )
        if ( $self->{debug_state} and $self->{debug_state} >= 2 );

    if ( $self->{cache_type} eq 'snapshot' ) {
        my $i = $self->{partition_id};
        $self->{edge}->on_save_snapshot( $i, $stored )
            if (defined $i
            and $self->{edge}
            and $self->{edge}->can('on_save_snapshot') );
    }
    my $message = Tachikoma::Message->new;
    $message->[TYPE]    = TM_STORABLE;
    $message->[FROM]    = $self->{name};
    $message->[TO]      = $self->{offsetlog};
    $message->[PAYLOAD] = $stored;
    Tachikoma->nodes->{_router}->fill($message);
    $self->{last_cache_size}    = $message->size;
    $self->{last_commit}        = $Tachikoma::Now;
    $self->{last_commit_offset} = $offset;
    return;
}

sub load_cache {
    my $self   = shift;
    my $stored = shift;
    if ( ref $stored ) {
        my $i = $self->{partition_id};
        $self->{saved_offset} = $stored->{offset};
        if ( $self->{edge} and defined $i ) {
            my $cache_type = $stored->{cache_type} // 'snapshot';
            if ( $cache_type eq 'snapshot' ) {
                if ( $self->{edge}->can('on_load_snapshot') ) {
                    $self->{cache} = $stored;
                }
            }
            elsif ( $cache_type eq 'window' ) {
                if ( $self->{edge}->can('on_load_window') ) {
                    $self->{edge}->on_load_window( $i, $stored );
                }
            }
        }
    }
    else {
        $self->print_less_often('WARNING: bad data in cache');
    }
    return;
}

sub load_cache_complete {
    my $self = shift;
    my $i    = $self->{partition_id};
    if ( $self->{edge} and defined $i ) {
        if ( $self->{cache_type} eq 'window' ) {
            if ( $self->{edge}->can('on_load_window_complete') ) {
                $self->{edge}->on_load_window_complete($i);
            }
            if ( $self->{edge}->can('on_save_window') ) {
                $self->{edge}->on_save_window->[$i] = sub {
                    $self->commit_offset(@_);
                    return;
                };
            }
        }
        else {
            if ( $self->{edge}->can('on_load_snapshot') ) {
                $self->{edge}->on_load_snapshot( $i, $self->{cache} );
                $self->{cache} = undef;
            }
        }
    }
    if ( defined $self->{saved_offset} ) {
        $self->{last_commit_offset} = $self->{saved_offset};
    }
    if ( $self->{debug_state} ) {
        $self->stderr(
            'DEBUG: LOAD_CACHE_COMPLETE beginning at ',
            $self->{saved_offset} // $self->{default_offset}
        );
    }
    $self->{last_commit} = $Tachikoma::Now;
    return;
}

sub restart {
    my $self = shift;
    $self->stderr('DEBUG: RESTART') if ( $self->{debug_state} );
    if ( defined $self->partition_id ) {
        $self->remove_node;
    }
    else {
        $self->arguments( $self->arguments );
        $self->set_timer(0);
    }
    return;
}

sub owner {
    my $self = shift;
    if (@_) {
        $self->{owner} = shift;
        $self->last_receive($Tachikoma::Now);
        $self->set_timer(0);
        $self->set_state('ACTIVE')
            if (not $self->{offsetlog}
            and not $self->{set_state}->{ACTIVE} );
    }
    return $self->{owner};
}

sub edge {
    my $self = shift;
    if (@_) {
        my $edge = shift;
        $self->{edge} = $edge;
        if ($edge) {
            my $i = $self->{partition_id};
            $self->last_receive($Tachikoma::Now);
            if ( defined $i ) {
                $edge->new_cache($i) if ( $edge->can('new_cache') );
            }
            else {
                $edge->new_cache if ( $edge->can('new_cache') );
            }
            $self->set_timer(0);
            $self->set_state('ACTIVE')
                if (not $self->{offsetlog}
                and not $self->{set_state}->{ACTIVE} );
        }
    }
    return $self->{edge};
}

sub remove_node {
    my $self = shift;
    $self->name(q());
    $self->next_offset(undef);
    if ( $self->{edge} and $self->{edge}->can('new_cache') ) {
        if ( defined $self->{partition_id} ) {
            $self->{edge}->new_cache( $self->{partition_id} );
        }
        else {
            $self->{edge}->new_cache;
        }
    }
    $self->SUPER::remove_node;
    return;
}

sub dump_config {
    my $self     = shift;
    my $response = q();
    if ( not defined $self->{partition_id} ) {
        $response = $self->SUPER::dump_config;
    }
    return $response;
}

sub partition {
    my $self = shift;
    if (@_) {
        $self->{partition} = shift;
    }
    return $self->{partition};
}

sub offsetlog {
    my $self = shift;
    if (@_) {
        $self->{offsetlog}   = shift;
        $self->{status}      = 'INIT';
        $self->{last_commit} = 0;
    }
    return $self->{offsetlog};
}

sub broker_id {
    my $self = shift;
    if (@_) {
        $self->{broker_id} = shift;
        my ( $host, $port ) = split m{:}, $self->{broker_id}, 2;
        $self->{host} = $host;
        $self->{port} = $port;
    }
    if ( not defined $self->{broker_id} ) {
        $self->{broker_id} = join q(:), $self->{host}, $self->{port};
    }
    return $self->{broker_id};
}

sub partition_id {
    my $self = shift;
    if (@_) {
        $self->{partition_id} = shift;
    }
    return $self->{partition_id};
}

sub offset {
    my $self = shift;
    if (@_) {
        $self->{offset} = shift;
    }
    return $self->{offset};
}

sub next_offset {
    my $self = shift;
    if (@_) {
        $self->{next_offset} = shift;
        my $new_buffer = q();
        $self->{buffer} = \$new_buffer;
        $self->{offset} = undef;
    }
    return $self->{next_offset};
}

sub buffer {
    my $self = shift;
    if (@_) {
        $self->{buffer} = shift;
    }
    return $self->{buffer};
}

sub async_interval {
    my $self = shift;
    if (@_) {
        $self->{async_interval} = shift;
    }
    return $self->{async_interval};
}

sub timeout {
    my $self = shift;
    if (@_) {
        $self->{timeout} = shift;
    }
    return $self->{timeout};
}

sub hub_timeout {
    my $self = shift;
    if (@_) {
        $self->{hub_timeout} = shift;
    }
    return $self->{hub_timeout};
}

sub last_receive {
    my $self = shift;
    if (@_) {
        $self->{last_receive} = shift;
    }
    return $self->{last_receive};
}

sub cache {
    my $self = shift;
    if (@_) {
        $self->{cache} = shift;
    }
    return $self->{cache};
}

sub cache_type {
    my $self = shift;
    if (@_) {
        $self->{cache_type} = shift;
    }
    return $self->{cache_type};
}

sub last_cache_size {
    my $self = shift;
    if (@_) {
        $self->{last_cache_size} = shift;
    }
    return $self->{last_cache_size};
}

sub auto_commit {
    my $self = shift;
    if (@_) {
        $self->{auto_commit} = shift;
    }
    return $self->{auto_commit};
}

sub default_offset {
    my $self = shift;
    if (@_) {
        $self->{default_offset} = shift;
        $self->next_offset(undef);
    }
    return $self->{default_offset};
}

sub last_commit {
    my $self = shift;
    if (@_) {
        $self->{last_commit} = shift;
    }
    return $self->{last_commit};
}

sub last_commit_offset {
    my $self = shift;
    if (@_) {
        $self->{last_commit_offset} = shift;
    }
    return $self->{last_commit_offset};
}

sub expecting {
    my $self = shift;
    if (@_) {
        $self->{expecting} = shift;
    }
    return $self->{expecting};
}

sub saved_offset {
    my $self = shift;
    if (@_) {
        $self->{saved_offset} = shift;
    }
    return $self->{saved_offset};
}

sub inflight {
    my $self = shift;
    if (@_) {
        $self->{inflight} = shift;
    }
    return $self->{inflight};
}

sub last_expire {
    my $self = shift;
    if (@_) {
        $self->{last_expire} = shift;
    }
    return $self->{last_expire};
}

sub msg_unanswered {
    my $self = shift;
    if (@_) {
        $self->{msg_unanswered} = shift;
    }
    return $self->{msg_unanswered};
}

sub max_unanswered {
    my $self = shift;
    if (@_) {
        $self->{max_unanswered} = shift;
    }
    return $self->{max_unanswered};
}

sub status {
    my $self = shift;
    if (@_) {
        $self->{status} = shift;
    }
    return $self->{status};
}

########################
# synchronous interface
########################

sub fetch {
    my $self     = shift;
    my $callback = shift;
    my $messages = [];
    my $target   = $self->target or return $messages;
    $self->{sync_error} = undef;
    $self->get_offset
        or return $messages
        if ( not defined $self->{next_offset} );
    return $messages
        if (defined $self->{auto_commit}
        and defined $self->{offset}
        and Time::HiRes::time - $self->{last_commit} >= $self->{auto_commit}
        and not $self->commit_offset_sync );
    usleep( $self->{poll_interval} * 1000000 )
        if ( $self->{eos} and $self->{poll_interval} );
    $self->{eos} = undef;
    my $request = Tachikoma::Message->new;
    $request->[TYPE]    = TM_REQUEST;
    $request->[TO]      = $self->{partition};
    $request->[PAYLOAD] = join q(), 'GET ', $self->{next_offset}, "\n";
    $target->callback( $self->get_batch_sync );
    my $okay = eval {
        $target->fill($request);
        $target->drain;
        return 1;
    };
    if ( not $okay ) {
        my $error = $@ || 'unknown error';
        chomp $error;
        $self->sync_error("FETCH: $error\n");
    }
    elsif ( not $target->{fh} ) {
        $self->sync_error("FETCH: lost connection\n");
    }
    $self->get_messages($messages);
    if ( @{$messages} ) {
        if ($callback) {
            &{$callback}( $self, $_ ) for ( @{$messages} );
        }
        $self->{last_receive} = Time::HiRes::time;
    }
    $self->retry_offset if ( $self->{sync_error} );
    return $messages;
}

sub get_offset {
    my $self   = shift;
    my $stored = undef;
    $self->cache(undef);
    if ( $self->offsetlog ) {
        my $consumer = Tachikoma::Nodes::Consumer->new( $self->offsetlog );
        $consumer->next_offset(-2);
        $consumer->broker_id( $self->broker_id );
        $consumer->timeout( $self->timeout );
        $consumer->hub_timeout( $self->hub_timeout );
        while (1) {
            my $messages = $consumer->fetch;
            my $error    = $consumer->sync_error // q();
            chomp $error;
            $self->sync_error("GET_OFFSET: $error\n") if ($error);
            last                                      if ( not @{$messages} );
            $stored = $messages->[-1]->payload;
        }
        if ( $self->sync_error ) {
            $self->remove_target;
            return;
        }
    }
    if ( $stored and defined $stored->{cache} ) {
        $self->cache( $stored->{cache} );
    }
    if ( $stored and defined $stored->{offset} ) {
        $self->next_offset( $stored->{offset} );
    }
    elsif ( $self->default_offset eq 'start' ) {
        $self->next_offset(0);
    }
    elsif ( $self->default_offset eq 'recent' ) {
        $self->next_offset(-2);
    }
    else {
        $self->next_offset(-1);
    }
    return 1;
}

sub get_batch_sync {
    my $self = shift;
    return sub {
        my $response  = shift;
        my $expecting = 1;
        if ( length $response->[ID] ) {
            my $offset = $response->[ID];
            my $eof    = $response->[TYPE] & TM_EOF;
            $self->{offset} //= $offset;
            if (    $self->{next_offset} > 0
                and $offset != $self->{next_offset} )
            {
                print {*STDERR} 'WARNING: skipping from ',
                    $self->{next_offset}, ' to ', $offset, "\n";
                my $new_buffer = q();
                $self->{buffer} = \$new_buffer;
                $self->{offset} = $offset;
            }
            if ($eof) {
                $self->{next_offset} = $offset;
                $self->{eos}         = $eof;
            }
            else {
                $self->{next_offset} = $offset + length $response->[PAYLOAD];
                ${ $self->{buffer} } .= $response->[PAYLOAD];
            }
            $expecting = undef;
        }
        elsif ( $response->[TYPE] & TM_REQUEST ) {
            $expecting = 1;
        }
        elsif ( $response->[PAYLOAD] ) {
            die $response->[PAYLOAD];
        }
        else {
            die $response->type_as_string . "\n";
        }
        return $expecting;
    };
}

sub get_messages {
    my $self     = shift;
    my $messages = shift;
    my $from     = $self->{partition_id};
    my $offset   = $self->{offset};
    my $buffer   = $self->{buffer};
    my $got      = length ${$buffer};

    # XXX:M
    # my $size =
    #     $got > VECTOR_SIZE
    #     ? VECTOR_SIZE + unpack 'N', ${$buffer}
    #     : 0;
    my $size = $got > VECTOR_SIZE ? unpack 'N', ${$buffer} : 0;
    while ( $got >= $size and $size > 0 ) {
        my $message =
            Tachikoma::Message->unpacked( \substr ${$buffer}, 0, $size, q() );
        $message->[FROM] = $from;
        $message->[ID]   = join q(:), $offset, $offset + $size;
        $offset += $size;
        $got    -= $size;

        # XXX:M
        # $size =
        #     $got > VECTOR_SIZE
        #     ? VECTOR_SIZE + unpack 'N', ${$buffer}
        #     : 0;
        $size = $got > VECTOR_SIZE ? unpack 'N', ${$buffer} : 0;
        push @{$messages}, $message;
    }
    $self->{offset} = $offset;
    return;
}

sub commit_offset_sync {
    my $self = shift;
    return 1 if ( $self->{last_commit} >= $self->{last_receive} );
    my $rv     = undef;
    my $target = $self->target or return;
    die "ERROR: no offsetlog specified\n" if ( not $self->offsetlog );
    my $message = Tachikoma::Message->new;
    $message->[TYPE] = TM_STORABLE;
    $message->[TO]   = $self->offsetlog;
    $message->payload(
        {   timestamp  => time,
            offset     => $self->offset,
            cache_type => 'snapshot',
            cache      => $self->cache,
        }
    );
    $rv = eval {
        $target->fill($message);
        return 1;
    };
    if ( not $rv ) {
        if ( not $target->fh ) {
            $self->sync_error("COMMIT_OFFSET: lost connection\n");
        }
        elsif ( not defined $self->sync_error ) {
            $self->sync_error("COMMIT_OFFSET: send_messages failed\n");
        }
        $self->retry_offset;
        $rv = undef;
    }
    $self->last_commit( $self->last_receive );
    return $rv;
}

sub reset_offset {
    my $self  = shift;
    my $cache = shift;
    $self->next_offset(0);
    $self->cache($cache);
    $self->last_commit(0);
    return $self->commit_offset_sync;
}

sub retry_offset {
    my $self = shift;
    $self->next_offset(undef);
    $self->cache(undef);
    $self->remove_target;
    return;
}

sub remove_target {
    my $self = shift;
    if ( $self->{target} ) {
        if ( $self->{target}->{fh} ) {
            close $self->{target}->{fh} or die "ERROR: couldn't close: $!";
            $self->{target}->{fh} = undef;
        }
        $self->{target} = undef;
        usleep( $self->{poll_interval} * 1000000 )
            if ( $self->{poll_interval} );
    }
    return;
}

sub host {
    my $self = shift;
    if (@_) {
        $self->{host} = shift;
    }
    return $self->{host};
}

sub port {
    my $self = shift;
    if (@_) {
        $self->{port} = shift;
    }
    return $self->{port};
}

sub target {
    my $self = shift;
    if (@_) {
        $self->{target} = shift;
    }
    if ( not defined $self->{target} ) {
        my $broker_id = $self->broker_id;
        my ( $host, $port ) = split m{:}, $broker_id, 2;
        $self->{target} = eval { Tachikoma->inet_client( $host, $port ) };
        $self->{target}->timeout( $self->{hub_timeout} )
            if ( $self->{target} );
        if ( not $self->{target} ) {
            $self->sync_error( $@ || "ERROR: connect: unknown error\n" );
            usleep( $self->{poll_interval} * 1000000 )
                if ( $self->{poll_interval} );
        }
    }
    return $self->{target};
}

sub poll_interval {
    my $self = shift;
    if (@_) {
        $self->{poll_interval} = shift;
    }
    return $self->{poll_interval};
}

sub eos {
    my $self = shift;
    if (@_) {
        $self->{eos} = shift;
    }
    return $self->{eos};
}

sub sync_error {
    my $self = shift;
    if (@_) {
        $self->{sync_error} = shift;
    }
    return $self->{sync_error};
}

1;
