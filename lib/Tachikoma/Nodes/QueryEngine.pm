#!/usr/bin/perl
# ----------------------------------------------------------------------
# Tachikoma::Nodes::QueryEngine
# ----------------------------------------------------------------------
#

package Tachikoma::Nodes::QueryEngine;
use strict;
use warnings;
use Tachikoma::Nodes::Index;
use Tachikoma::Message qw(
    TYPE FROM TO ID STREAM PAYLOAD
    TM_BYTESTREAM TM_STORABLE TM_ERROR TM_EOF
);
use parent qw( Tachikoma::Nodes::Index );

use version; our $VERSION = qv('v2.0.197');

my %OPERATORS = ();

sub help {
    my $self = shift;
    return <<'EOF';
make_node QueryEngine <name> <index1> <index2> ...
EOF
}

sub new {
    my $class = shift;
    my $self  = $class->SUPER::new;
    $self->{indexes}    = undef;
    $self->{host_ports} = undef;
    $self->{results}    = undef;
    $self->{offsets}    = undef;
    $self->{messages}   = undef;
    bless $self, $class;
    return $self;
}

sub arguments {
    my $self = shift;
    if (@_) {
        $self->{arguments} = shift;
        my @indexes = split q( ), $self->{arguments};
        $self->{indexes} = { map { $_ => 1 } @indexes };
    }
    return $self->{arguments};
}

sub fill {
    my ( $self, $message ) = @_;
    my $query = $message->payload;
    if ( $message->[TYPE] & TM_STORABLE ) {
        my $value = eval { $self->execute($query) };
        $value //= { error => $@ };
        my $response = Tachikoma::Message->new;
        $response->[TYPE]    = ref $value ? TM_STORABLE : TM_BYTESTREAM;
        $response->[FROM]    = $self->{name};
        $response->[TO]      = $message->[FROM];
        $response->[ID]      = $message->[ID];
        $response->[STREAM]  = $message->[STREAM];
        $response->[PAYLOAD] = $value;
        $self->{sink}->fill($response);
        $self->{counter}++;
    }
    elsif ( not $message->[TYPE] & TM_ERROR
        and not $message->[TYPE] & TM_EOF )
    {
        $self->stderr( 'ERROR: bad request from: ', $message->[FROM] );
    }
    return;
}

sub execute {
    my ( $self, $query ) = @_;
    my $results = undef;
    if ( ref $query eq 'ARRAY' ) {
        $results = &{ $OPERATORS{'and'} }( $self, { q => $query } );
    }
    elsif ( ref $query eq 'HASH' ) {
        my $op = $query->{op};
        die qq("$op" is not a valid operator\n) if ( not $OPERATORS{$op} );
        $results = &{ $OPERATORS{$op} }( $self, $query );
    }
    $results //= {};
    return $results;
}

$OPERATORS{'and'} = sub {
    my ( $self, $query ) = @_;
    my %rv = ();
    for my $subquery ( @{ $query->{q} } ) {
        my $value = $self->execute($subquery);
        $rv{$_}++ for ( keys %{$value} );
    }
    return \%rv;
};

$OPERATORS{'or'} = sub {
    my ( $self, $query ) = @_;
    my %rv = ();
    for my $subquery ( @{ $query->{q} } ) {
        my $value = $self->execute($subquery);
        $rv{$_} = 1 for ( keys %{$value} );
    }
    return \%rv;
};

$OPERATORS{'eq'} = sub {
    my ( $self, $query ) = @_;
    return $self->lookup( $query->{field}, $query->{key} );
};

$OPERATORS{'ne'} = sub {
    my ( $self, $query ) = @_;
    return $self->lookup( $query->{field}, $query->{key}, 'negate' );
};

$OPERATORS{'re'} = sub {
    my ( $self, $query ) = @_;
    return $self->search( $query->{field}, $query->{key} );
};

$OPERATORS{'nr'} = sub {
    my ( $self, $query ) = @_;
    return $self->search( $query->{field}, $query->{key}, 'negate' );
};

$OPERATORS{'ge'} = sub {
    my ( $self, $query ) = @_;
    return $self->range( $query->{field}, $query->{key}, undef );
};

$OPERATORS{'le'} = sub {
    my ( $self, $query ) = @_;
    return $self->range( $query->{field}, undef, $query->{key} );
};

$OPERATORS{'range'} = sub {
    my ( $self, $query ) = @_;
    return $self->range( $query->{field}, $query->{from}, $query->{to} );
};

$OPERATORS{'keys'} = sub {
    my ( $self, $query ) = @_;
    return $self->get_keys( $query->{field} );
};

sub lookup {
    my ( $self, $field, $key, $negate ) = @_;
    return $self->get_index($field)->lookup( $key, $negate );
}

sub search {
    my ( $self, $field, $key, $negate ) = @_;
    return $self->get_index($field)->search( $key, $negate );
}

sub range {
    my ( $self, $field, $from, $to ) = @_;
    return $self->get_index($field)->range( $from, $to );
}

sub get_keys {
    my ( $self, $field ) = @_;
    return $self->get_index($field)->get_keys;
}

sub get_index {
    my ( $self, $field ) = @_;
    die "no such field: $field\n" if ( not $self->{indexes}->{$field} );
    my $node = $Tachikoma::Nodes{$field};
    die "invalid field: $field\n"
        if ( not $node->isa('Tachikoma::Nodes::Index') );
    return $node;
}

########################
# synchronous interface
########################

sub query {
    my ( $self, $query ) = @_;
    die 'ERROR: no query' if ( not ref $query );
    my $responses   = {};
    my $num_queries = ref $query eq 'ARRAY' ? scalar @{$query} : 1;
    my @results     = ();
    my %join        = ();
    my %offsets     = ();
    my @messages    = ();
    my %counts      = ();
    my $request     = Tachikoma::Message->new;
    $request->type(TM_STORABLE);
    $request->to('QueryEngine');
    $request->payload($query);
    $self->send_request( $request, $responses );

    for my $host_port ( keys %{ $self->{connector} } ) {
        my $tachikoma = $self->{connector}->{$host_port};
        $tachikoma->drain;
        my $payload = $responses->{$host_port};
        if ( $payload->{error} ) {
            push @messages, $payload;
            last;
        }
        elsif ( ref $query eq 'HASH' and $query->{op} eq 'keys' ) {
            $counts{$_} += $payload->{$_} for ( keys %{$payload} );
        }
        else {
            for my $entry ( keys %{$payload} ) {
                $join{$entry} += $payload->{$entry};
            }
        }
    }
    if ( ref $query eq 'HASH' and $query->{op} eq 'keys' ) {
        @messages = \%counts;
    }
    else {
        for my $entry ( keys %join ) {
            next if ( $join{$entry} < $num_queries );
            push @results, $entry;
            $offsets{$entry} = 1;
        }
    }
    $self->{results}  = [ sort @results ];
    $self->{offsets}  = \%offsets;
    $self->{messages} = \@messages;
    return;
}

sub send_request {
    my ( $self, $request, $responses ) = @_;
    $self->{connector} ||= {};
    for my $host_port ( @{ $self->host_ports } ) {
        my $tachikoma = $self->{connector}->{$host_port};
        if ( not $tachikoma ) {
            my ( $host, $port ) = split m{:}, $host_port;
            $tachikoma =
                eval { return Tachikoma->inet_client( $host, $port ) };
            next if ( not $tachikoma );
            $self->{connector}->{$host_port} = $tachikoma;
        }
        $tachikoma->callback(
            sub {
                my $message = shift;
                if ( $message->type & TM_STORABLE ) {
                    $responses->{$host_port} = $message->payload;
                }
                elsif ( $message->type & TM_ERROR ) {
                    die 'ERROR: query failed: ' . $message->payload;
                }
                else {
                    die 'ERROR: query failed: unknown error';
                }
                return;
            }
        );
        $tachikoma->fill($request);
    }
    return;
}

sub fetchrow {
    my $self = shift;
    if ( @{ $self->{results} } and not @{ $self->{messages} } ) {
        my $offsets = $self->{offsets};
        while ( my $entry = shift @{ $self->{results} } ) {
            my ( $partition, $offset ) = split m{:}, $entry, 2;
            next if ( not defined $offset or not $offsets->{$entry} );
            $self->{messages} =
                $self->fetch_offset( $partition, $offset, $offsets );
            next if ( not @{ $self->{messages} } );
            last;
        }
    }
    return shift @{ $self->{messages} };
}

# async support
sub indexes {
    my $self = shift;
    if (@_) {
        $self->{indexes} = shift;
    }
    return $self->{indexes};
}

# sync support
sub host_ports {
    my $self = shift;
    if (@_) {
        $self->{host_ports} = shift;
    }
    return $self->{host_ports};
}

sub results {
    my $self = shift;
    if (@_) {
        $self->{results} = shift;
    }
    return $self->{results};
}

sub offsets {
    my $self = shift;
    if (@_) {
        $self->{offsets} = shift;
    }
    return $self->{offsets};
}

sub messages {
    my $self = shift;
    if (@_) {
        $self->{messages} = shift;
    }
    return $self->{messages};
}

1;
