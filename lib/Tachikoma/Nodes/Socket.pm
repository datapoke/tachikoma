#!/usr/bin/perl
# ----------------------------------------------------------------------esn't s
# Tachikoma::Nodes::Socket
# ----------------------------------------------------------------------
#
# Tachikomatic IPC - send and receive messages over sockets
#                  - RSA/Ed25519 handshakes
#                  - TLSv1
#                  - heartbeats and latency scores to reset bad connections
#                  - on_EOF: close, send, ignore, shutdown, die, reconnect
#

package Tachikoma::Nodes::Socket;
use strict;
use warnings;
use Tachikoma::Nodes::FileHandle qw( TK_R TK_W TK_SYNC setsockopts );
use Tachikoma::Message           qw(
    TYPE FROM TO ID TIMESTAMP PAYLOAD
    TM_BYTESTREAM TM_HEARTBEAT TM_REQUEST TM_RESPONSE TM_ERROR
    VECTOR_SIZE
);
use Tachikoma::Crypto;
use Digest::MD5 qw( md5 );
use Socket      qw(
    PF_UNIX PF_INET SOCK_STREAM SOL_SOCKET SOMAXCONN
    SO_REUSEADDR SO_SNDBUF SO_RCVBUF SO_SNDLOWAT SO_KEEPALIVE
    inet_aton inet_ntoa pack_sockaddr_in unpack_sockaddr_in
    pack_sockaddr_un
);
use POSIX qw( F_SETFL O_NONBLOCK EAGAIN SIGUSR1 );
my $USE_SODIUM;

BEGIN {
    $USE_SODIUM = eval {
        my $module_name = 'Crypt::NaCl::Sodium';
        my $module_path = 'Crypt/NaCl/Sodium.pm';
        require $module_path;
        import $module_name qw( :utils );
        return 1;
    };
}
use vars   qw( @EXPORT_OK );
use parent qw( Tachikoma::Nodes::FileHandle Tachikoma::Crypto );
@EXPORT_OK = qw( TK_R TK_W TK_SYNC setsockopts );

use version; our $VERSION = qv('v2.0.195');

use constant DEFAULT_PORT => 4230;

sub unix_server {
    my $class    = shift;
    my $filename = shift;
    my $perms    = shift;
    my $gid      = shift;
    my $socket;
    socket $socket, PF_UNIX, SOCK_STREAM, 0 or die "FAILED: socket: $!";
    setsockopts($socket);
    bind $socket, pack_sockaddr_un($filename) or die "ERROR: bind: $!\n";
    listen $socket, SOMAXCONN or die "FAILED: listen: $!";
    die "FAILED: stat says $filename isn't a socket"
        if ( not -S $filename );
    chmod oct $perms, $filename or die "ERROR: chmod: $!" if ($perms);
    chown $>, $gid, $filename or die "ERROR: chown: $!" if ($gid);
    my $server = $class->new;
    $server->{type}      = 'listen';
    $server->{filename}  = $filename;
    $server->{fileperms} = $perms;
    $server->{filegid}   = $gid;
    $server->fh($socket);
    return $server->register_server_node;
}

sub unix_client {
    my $class    = shift;
    my $filename = shift;
    my $flags    = shift;
    my $socket;
    socket $socket, PF_UNIX, SOCK_STREAM, 0 or die "FAILED: socket: $!";
    setsockopts($socket);
    my $client = $class->new($flags);
    $client->{type}          = 'connect';
    $client->{filename}      = $filename;
    $client->{last_upbeat}   = $Tachikoma::Now;
    $client->{last_downbeat} = $Tachikoma::Now;
    $client->fh($socket);

    # this has to happen after fh() sets O_NONBLOCK correctly:
    if ( not connect $socket, pack_sockaddr_un($filename) ) {
        $client->remove_node;
        die "ERROR: connect: $!\n";
    }
    $client->init_connect;
    $client->register_reader_node;
    return $client;
}

sub unix_client_async {
    my $class    = shift;
    my $filename = shift;
    my $client   = $class->new;
    $client->{type}          = 'connect';
    $client->{filename}      = $filename;
    $client->{last_upbeat}   = $Tachikoma::Now;
    $client->{last_downbeat} = $Tachikoma::Now;
    push @{ Tachikoma->nodes_to_reconnect }, $client;
    return $client;
}

sub inet_server {
    my $class    = shift;
    my $hostname = shift;
    my $port     = shift;
    my $iaddr    = inet_aton($hostname) or die "ERROR: no host: $hostname\n";
    my $sockaddr = pack_sockaddr_in( $port, $iaddr );
    my $proto    = getprotobyname 'tcp';
    my $socket;
    socket $socket, PF_INET, SOCK_STREAM, $proto
        or die "FAILED: socket: $!";
    setsockopt $socket, SOL_SOCKET, SO_REUSEADDR, 1
        or die "FAILED: setsockopt: $!";
    setsockopts($socket);
    bind $socket, pack_sockaddr_in( $port, $iaddr )
        or die "ERROR: bind: $!\n";
    listen $socket, SOMAXCONN or die "FAILED: listen: $!";
    my $server = $class->new;
    $server->{type}    = 'listen';
    $server->{address} = $iaddr;
    $server->{port}    = $port;
    $server->fh($socket);
    return $server->register_server_node;
}

sub inet_client {
    my $class    = shift;
    my $hostname = shift;
    my $port     = shift or die "FAILED: no port specified for $hostname";
    my $flags    = shift;
    my $iaddr    = inet_aton($hostname) or die "ERROR: no host: $hostname\n";
    my $proto    = getprotobyname 'tcp';
    my $socket;
    socket $socket, PF_INET, SOCK_STREAM, $proto
        or die "FAILED: socket: $!";
    setsockopts($socket);
    my $client = $class->new($flags);
    $client->{type}          = 'connect';
    $client->{hostname}      = $hostname;
    $client->{address}       = $iaddr;
    $client->{port}          = $port;
    $client->{last_upbeat}   = $Tachikoma::Now;
    $client->{last_downbeat} = $Tachikoma::Now;
    $client->fh($socket);

    # this has to happen after fh() sets O_NONBLOCK correctly:
    if (    not( connect $socket, pack_sockaddr_in( $port, $iaddr ) )
        and defined $flags
        and $flags & TK_SYNC )
    {
        $client->remove_node;
        die "ERROR: connect: $!\n";
    }
    $client->init_connect;
    $client->register_reader_node;
    return $client;
}

sub inet_client_async {
    my $class    = shift;
    my $hostname = shift;
    my $port     = shift or die "FAILED: no port specified for $hostname";
    my $client   = $class->new;
    $client->{type}          = 'connect';
    $client->{hostname}      = $hostname;
    $client->{port}          = $port;
    $client->{last_upbeat}   = $Tachikoma::Now;
    $client->{last_downbeat} = $Tachikoma::Now;
    push @{ Tachikoma->nodes_to_reconnect }, $client;
    return $client;
}

sub new {
    my $proto        = shift;
    my $class        = ref($proto) || $proto;
    my $flags        = shift       || 0;
    my $self         = $class->SUPER::new;
    my $input_buffer = q();
    $self->{type}             = 'socket';
    $self->{flags}            = $flags;
    $self->{on_EOF}           = 'close';
    $self->{parent}           = undef;
    $self->{hostname}         = undef;
    $self->{address}          = undef;
    $self->{port}             = undef;
    $self->{filename}         = undef;
    $self->{fileperms}        = undef;
    $self->{filegid}          = undef;
    $self->{auth_challenge}   = undef;
    $self->{auth_timestamp}   = undef;
    $self->{auth_complete}    = undef;
    $self->{scheme}           = Tachikoma->scheme;
    $self->{delegates}        = {};
    $self->{drain_fh}         = \&Tachikoma::Nodes::FileHandle::drain_fh;
    $self->{drain_buffer}     = \&drain_buffer_normal;
    $self->{fill_fh}          = \&Tachikoma::Nodes::FileHandle::fill_fh;
    $self->{last_upbeat}      = undef;
    $self->{last_downbeat}    = undef;
    $self->{latency_score}    = undef;
    $self->{inet_aton_serial} = undef;
    $self->{registrations}->{CONNECTED}     = {};
    $self->{registrations}->{AUTHENTICATED} = {};
    $self->{registrations}->{RECONNECT}     = {};
    $self->{fill_modes}                     = {
        null            => \&Tachikoma::Nodes::FileHandle::null_cb,
        unauthenticated => \&do_not_enter,
        init            => \&fill_buffer_init,
        fill            => $flags & TK_SYNC
        ? \&Tachikoma::Nodes::FileHandle::fill_fh_sync
        : \&Tachikoma::Nodes::FileHandle::fill_buffer
    };
    $self->{fill} = $self->{fill_modes}->{fill};
    bless $self, $class;
    return $self;
}

sub register_server_node {
    my $self = shift;
    $Tachikoma::Event_Framework->register_server_node($self);
    $self->{drain_fh} = \&accept_connections;
    $self->{fill}     = \&Tachikoma::Nodes::FileHandle::null_cb;
    return $self;
}

sub accept_connections {
    my (@args) = @_;
    return $Tachikoma::Event_Framework->accept_connections(@args);
}

sub accept_connection {
    my $self   = shift;
    my $server = $self->{fh};
    my $secure = Tachikoma->configuration->{secure_level};
    return if ( defined $secure and $secure == 0 );
    my $client;
    my $paddr = accept $client, $server;
    if ( not $paddr ) {
        $self->stderr("ERROR: couldn't accept_connection: $!\n")
            if ( $! != EAGAIN );
        return;
    }
    my $node = $self->new;

    $node->{type} = 'accept';
    $node->fh($client);
    my $name = undef;
    if ( $self->{filename} ) {
        my $my_name = $self->{name};
        do {
            $name = join q(:), $my_name, Tachikoma->counter;
        } while ( exists $Tachikoma::Nodes{$name} );
    }
    else {
        my ( $port, $address ) = unpack_sockaddr_in($paddr);
        $name = join q(:), inet_ntoa($address), $port;
        if ( exists $Tachikoma::Nodes{$name} ) {
            $self->stderr("WARNING: $name exists");
            return $node->remove_node;
        }
    }
    $node->name($name);
    $node->{parent}      = $self->{name};
    $node->{owner}       = $self->{owner};
    $node->{sink}        = $self->{sink};
    $node->{edge}        = $self->{edge};
    $node->{on_EOF}      = $self->{on_EOF};
    $node->{scheme}      = $self->{scheme};
    $node->{delegates}   = $self->{delegates};
    $node->{debug_state} = $self->{debug_state};
    $node->{fill}        = $node->{fill_modes}->{unauthenticated};
    $node->set_drain_buffer;

    for my $event ( keys %{ $self->{registrations} } ) {
        my $r = $self->{registrations}->{$event};
        $node->{registrations}->{$event} =
            { map { $_ => defined $r->{$_} ? 0 : undef } keys %{$r} };
    }
    $node->register_reader_node;
    $node->init_accept;
    $self->{counter}++;
    return;
}

sub init_socket {
    my $self    = shift;
    my $payload = shift;
    #
    # Earlier we forked our own resolver job and sent it a
    # message with the hostname.  When fill_buffer_init() received
    # the response it called init_socket() with the address:
    #
    my $address = ( $payload =~ m{^(\d+[.]\d+[.]\d+[.]\d+)$} )[0];
    if ( not $address ) {
        $self->{address} = pack 'H*', '00000000';
        $self->print_less_often(
            'WARNING: name lookup failed, invalid address');
        return $self->close_filehandle('reconnect');
    }
    my $iaddr = inet_aton($address) or die "FAILED: no host: $address";
    my $proto = getprotobyname 'tcp';
    my $socket;
    socket $socket, PF_INET, SOCK_STREAM, $proto or die "FAILED: socket: $!";
    setsockopts($socket);
    $self->close_filehandle;
    $self->{address} = $iaddr;
    $self->{fill}    = $self->{fill_modes}->{fill};
    $self->fh($socket);
    ## no critic (RequireCheckedSyscalls)
    connect $socket, pack_sockaddr_in( $self->{port}, $iaddr );
    ## use critic

    $self->register_reader_node;
    return $self->init_connect;
}

sub init_connect {
    my $self = shift;
    $self->{auth_challenge} = rand;
    if ( $self->{flags} & TK_SYNC ) {
        $self->reply_to_server_challenge;
    }
    else {
        $self->{drain_fh} = \&reply_to_server_challenge;
        $self->{fill_fh}  = \&Tachikoma::Nodes::FileHandle::null_cb;
    }
    delete $self->{set_state}->{EOF};
    delete $self->{set_state}->{RECONNECT};
    $self->set_state('CONNECTED');
    return;
}

sub init_accept {
    my $self = shift;
    $self->{auth_challenge} = rand;
    $self->{drain_fh}       = \&auth_client_response;
    $self->{fill_fh}        = \&Tachikoma::Nodes::FileHandle::fill_fh;
    my $message =
        $self->command( 'challenge', 'client',
        md5( $self->{auth_challenge} ) );
    $message->[ID] = $self->{configuration}->{wire_version};
    $self->{auth_timestamp} = $message->[TIMESTAMP];
    push @{ $self->{output_buffer} }, $message->packed;
    $self->register_writer_node;
    $self->set_state('CONNECTED');
    return;
}

sub reply_to_server_challenge {
    my $self = shift;
    my ( $got, $message ) =
        $self->reply_to_challenge( 'client', \&auth_server_response,
        \&Tachikoma::Nodes::FileHandle::fill_fh );
    return if ( not $message );
    my $response =
        $self->command( 'challenge', 'server',
        md5( $self->{auth_challenge} ) );
    $response->[ID] = $self->{configuration}->{wire_version};
    $self->{auth_timestamp} = $response->[TIMESTAMP];
    if ( $self->{flags} & TK_SYNC ) {
        my $rv = syswrite $self->{fh},
            ${ $message->packed } . ${ $response->packed };
        die "ERROR: reply_to_server_challenge couldn't write: $!\n"
            if ( not $rv );
    }
    else {
        unshift @{ $self->{output_buffer} },
            $message->packed, $response->packed;
        $self->register_writer_node;
    }
    if ( $got > 0 ) {
        $self->stderr(
            "WARNING: discarding $got extra bytes from server challenge.");
        my $new_buffer = q();
        $self->{input_buffer} = \$new_buffer;
    }
    return;
}

sub auth_client_response {
    my $self = shift;
    my $got  = $self->auth_response( 'client', \&reply_to_client_challenge,
        \&Tachikoma::Nodes::FileHandle::null_cb );
    $self->reply_to_client_challenge if ($got);
    return;
}

sub reply_to_client_challenge {
    my $self = shift;
    my ( $got, $message ) = $self->reply_to_challenge(
        'server',
        \&Tachikoma::Nodes::FileHandle::drain_fh,
        \&Tachikoma::Nodes::FileHandle::fill_fh
    );
    return if ( not $message );
    unshift @{ $self->{output_buffer} }, $message->packed;
    $self->register_writer_node;
    $self->{auth_complete} = $Tachikoma::Now;
    $self->set_state('AUTHENTICATED');
    $self->{fill} = $self->{fill_modes}->{fill};
    &{ $self->{drain_buffer} }( $self, $self->{input_buffer} ) if ($got);
    return;
}

sub auth_server_response {
    my $self = shift;
    my $got  = $self->auth_response(
        'server',
        \&Tachikoma::Nodes::FileHandle::drain_fh,
        \&Tachikoma::Nodes::FileHandle::fill_fh
    );
    $self->{auth_complete} = $Tachikoma::Now;
    $self->set_state('AUTHENTICATED');
    &{ $self->{drain_buffer} }( $self, $self->{input_buffer} ) if ($got);
    return;
}

sub reply_to_challenge {
    my $self       = shift;
    my $type       = shift;
    my $drain_func = shift;
    my $fill_func  = shift;
    my $other      = $type eq 'server' ? 'client' : 'server';
    my ( $got, $message ) = $self->read_block(65536);
    return if ( not $message );
    my $version = $message->[ID];
    my $config  = $self->{configuration};

    if ( not $version or $version ne $config->{wire_version} ) {
        my $caller = ( split m{::}, ( caller 1 )[3] )[-1];
        $self->stderr("ERROR: $caller failed: version mismatch");
        return $self->handle_EOF;
    }
    my $command = eval { Tachikoma::Command->new( $message->[PAYLOAD] ) };
    if ( not $command ) {
        my $error = $@ || 'unknown error';
        $self->stderr("WARNING: reply_to_challenge failed: $error");
        return $self->handle_EOF;
    }
    elsif ( $command->{arguments} ne $type ) {
        $self->stderr(
            'ERROR: reply_to_challenge failed: wrong challenge type');
        return $self->handle_EOF;
    }
    elsif ( length $config->{id}
        and not $self->verify_signature( $other, $message, $command ) )
    {
        return $self->handle_EOF;
    }
    $command->sign( $self->scheme, $message->timestamp );
    $message->payload( $command->packed );
    $self->{counter}++;
    $self->{drain_fh} = $drain_func;
    $self->{fill_fh}  = $fill_func;
    return ( $got, $message );
}

sub auth_response {
    my $self       = shift;
    my $type       = shift;
    my $drain_func = shift;
    my $fill_func  = shift;
    my ( $got, $message ) = $self->read_block(65536);
    return if ( not $message );
    my $caller  = ( split m{::}, ( caller 1 )[3] )[-1];
    my $version = $message->[ID];
    my $config  = $self->{configuration};
    my $command = eval { Tachikoma::Command->new( $message->[PAYLOAD] ) };

    if ( not $command ) {
        my $error = $@ || 'unknown error';
        $self->stderr("ERROR: $caller failed: $error");
        return $self->handle_EOF;
    }
    elsif ( not $version or $version ne $config->{wire_version} ) {
        $self->stderr("ERROR: $caller failed: version mismatch");
        return $self->handle_EOF;
    }
    elsif ( $command->{arguments} ne $type ) {
        $self->stderr("ERROR: $caller failed: wrong challenge type");
        return $self->handle_EOF;
    }
    elsif ( length $config->{id}
        and not $self->verify_signature( $type, $message, $command ) )
    {
        return $self->handle_EOF;
    }
    if ( $message->[TIMESTAMP] ne $self->{auth_timestamp} ) {
        $self->stderr("ERROR: $caller failed: incorrect timestamp");
        return $self->handle_EOF;
    }
    elsif ( $command->{payload} ne md5( $self->{auth_challenge} ) ) {
        $self->stderr("ERROR: $caller failed: incorrect response");
        return $self->handle_EOF;
    }
    $self->{counter}++;
    $self->{auth_challenge} = undef;
    $self->{drain_fh}       = $drain_func;
    $self->{fill_fh}        = $fill_func;
    return $got;
}

sub verify_signature {
    my $self    = shift;
    my $type    = shift;
    my $message = shift;
    my $command = shift;
    my $id      = ( split m{\n}, $command->{signature}, 2 )[0];
    if ( not $self->SUPER::verify_signature( $type, $message, $command ) ) {
        return;
    }
    elsif ( not $self->delegate_authorization( 'tachikoma', "$id\n" ) ) {
        $self->stderr("ERROR: $id not allowed to connect");
        return;
    }
    return 1;
}

sub read_block {
    my $self     = shift;
    my $buf_size = shift       or die 'FAILED: missing buf_size';
    my $fh       = $self->{fh} or return;
    my $buffer   = $self->{input_buffer};
    my $got      = length ${$buffer};
    my $read     = sysread $fh, ${$buffer}, $buf_size, $got;
    my $again    = $! == EAGAIN;
    my $error    = $!;
    $got += $read if ( defined $read );

    # XXX:M
    # my $size =
    #     $got > VECTOR_SIZE
    #     ? VECTOR_SIZE + unpack 'N', ${$buffer}
    #     : 0;
    my $size = $got > VECTOR_SIZE ? unpack 'N', ${$buffer} : 0;
    if ( $size > $buf_size ) {
        my $caller = ( split m{::}, ( caller 2 )[3] )[-1];
        $self->stderr("ERROR: $caller failed: size $size > $buf_size");
        return $self->handle_EOF;
    }
    if ( $got >= $size and $size > 0 ) {
        my $message = eval {
            Tachikoma::Message->unpacked( \substr ${$buffer}, 0, $size, q() );
        };
        if ( not $message ) {
            my $trap = $@ || 'unknown error';
            $self->stderr("WARNING: read_block failed: $trap");
            return $self->handle_EOF;
        }
        $got -= $size;
        $self->{input_buffer} = $buffer;
        return ( $got, $message );
    }
    if ( not defined $read or ( $read < 1 and not $again ) ) {
        my $caller = ( split m{::}, ( caller 2 )[3] )[-1];
        $self->print_least_often("WARNING: $caller couldn't read: $error")
            if ( not defined $read and $! ne 'Connection reset by peer' );
        return $self->handle_EOF;
    }
    return;
}

sub delegate_authorization {
    my $self     = shift;
    my $type     = shift;
    my $peer     = shift;
    my $delegate = $self->{delegates}->{$type} or return 1;
    require Tachikoma::Nodes::Callback;
    my $ruleset = $Tachikoma::Nodes{$delegate};
    if ( not $ruleset ) {
        $self->stderr("ERROR: couldn't get $delegate");
        $self->remove_node;
        return;
    }
    my $allowed     = undef;
    my $destination = Tachikoma::Nodes::Callback->new;
    my $message     = Tachikoma::Message->new;
    $message->[TYPE]    = TM_BYTESTREAM;
    $message->[PAYLOAD] = $peer;
    $destination->callback( sub { $allowed = 1 } );
    $ruleset->{sink} = $destination;
    $ruleset->fill($message);
    $ruleset->{sink} = undef;
    return $allowed;
}

sub drain_buffer_normal {
    my $self   = shift;
    my $buffer = shift;
    my $name   = $self->{name};
    my $sink   = $self->{sink};
    my $owner  = $self->{owner};
    my $got    = length ${$buffer};

    # XXX:M
    # my $size =
    #     $got > VECTOR_SIZE
    #     ? VECTOR_SIZE + unpack 'N', ${$buffer}
    #     : 0;
    my $size = $got > VECTOR_SIZE ? unpack 'N', ${$buffer} : 0;
    while ( $got >= $size and $size > 0 ) {
        my $message =
            Tachikoma::Message->unpacked( \substr ${$buffer}, 0, $size, q() );
        $got -= $size;
        $self->{bytes_read} += $size;
        $self->{counter}++;

        # XXX:M
        # $size =
        #     $got > VECTOR_SIZE
        #     ? VECTOR_SIZE + unpack 'N', ${$buffer}
        #     : 0;
        $size = $got > VECTOR_SIZE ? unpack 'N', ${$buffer} : 0;
        if ( $message->[TYPE] & TM_HEARTBEAT ) {
            $self->reply_to_heartbeat($message);
            next;
        }
        $message->[FROM] = join q(/), grep length, $name, $message->[FROM];
        if ( not $message->[TYPE] & TM_RESPONSE ) {
            if ( length $message->[TO] and length $owner ) {
                $self->drop_message( $message,
                    "message addressed while owner is set to $owner" )
                    if ( $message->[TYPE] != TM_ERROR );
                next;
            }
            $message->[TO] = $owner if ( length $owner );
        }
        $sink->fill($message);
    }
    return $got;
}

sub reply_to_heartbeat {
    my $self    = shift;
    my $message = shift;
    $self->{last_downbeat} = $Tachikoma::Now;
    if ( $message->[PAYLOAD] !~ m{^[\d.]+$} ) {
        $self->stderr( 'ERROR: bad heartbeat payload: ',
            $message->[PAYLOAD] );
    }
    elsif ( $self->{type} eq 'accept' ) {
        $self->fill($message);
    }
    else {
        my $latency = $Tachikoma::Right_Now - $message->[PAYLOAD];
        my $threshold =
            $self->{configuration}->{var}->{bad_ping_threshold} || 1;
        if ( $latency > $threshold ) {
            my $score = $self->{latency_score} || 0;
            if ( $score < $threshold ) {
                $score = $threshold;
            }
            else {
                $score += $latency > $score ? $score : $latency;
            }
            $self->{latency_score} = $score;
        }
        else {
            $self->{latency_score} = $latency;
        }
    }
    return;
}

sub do_not_enter {
    my $self = shift;
    return $self->stderr('ERROR: not yet authenticated - message discarded');
}

sub fill_buffer_init {
    my $self    = shift;
    my $message = shift;
    $message->[TO] = join q(/), grep length, $self->{name}, $message->[TO];
    $Tachikoma::Nodes{'_router'}->send_error( $message, 'NOT_AVAILABLE' );
    return;
}

sub handle_EOF {
    my $self   = shift;
    my $on_EOF = $self->{on_EOF};
    if ( $on_EOF eq 'reconnect' ) {
        push @Tachikoma::Closing, sub {
            $self->close_filehandle('reconnect');
        };
    }
    $self->SUPER::handle_EOF;
    return;
}

sub close_filehandle {
    my $self      = shift;
    my $reconnect = shift;
    $self->SUPER::close_filehandle;
    if ( $self->{type} eq 'listen' and $self->{filename} ) {
        unlink $self->{filename} or $self->stderr("ERROR: unlink: $!");
    }
    if ( $self->{last_upbeat} ) {
        $self->{last_upbeat}   = $Tachikoma::Now;
        $self->{last_downbeat} = $Tachikoma::Now;
    }
    delete $self->{set_state}->{CONNECTED};
    delete $self->{set_state}->{AUTHENTICATED};
    if ( $reconnect and $self->{on_EOF} eq 'reconnect' ) {
        my $reconnecting = Tachikoma->nodes_to_reconnect;
        my $exists       = ( grep $_ eq $self, @{$reconnecting} )[0];
        push @{$reconnecting}, $self if ( not $exists );
        $self->set_state('RECONNECT');
    }
    return;
}

sub reconnect {
    my $self = shift;
    my $rv   = undef;
    return if ( not $self->{sink} );
    my $secure = Tachikoma->configuration->{secure_level};
    return $self->close_filehandle('reconnect')
        if ( defined $secure and $secure == 0 );
    if ( $self->{filename} ) {
        $rv = $self->reconnect_unix;
    }
    else {
        $rv = $self->reconnect_inet;
    }
    return $rv;
}

sub reconnect_unix {
    my $self   = shift;
    my $socket = $self->{fh};
    my $rv     = undef;
    if ( not $socket or not fileno $socket ) {
        socket $socket, PF_UNIX, SOCK_STREAM, 0
            or die "FAILED: socket: $!";
        setsockopts($socket);
        $self->close_filehandle;
        $self->{fill} = $self->{fill_modes}->{fill};
        $self->fh($socket);
        if ( not connect $socket, pack_sockaddr_un( $self->{filename} ) ) {
            $self->print_less_often(
                "WARNING: reconnect: couldn't connect: $!");
            $self->close_filehandle;
            return 'try again';
        }
        $self->{high_water_mark}  = 0;
        $self->{largest_msg_sent} = 0;
        $self->{latency_score}    = undef;
    }
    my $okay = eval {
        $self->register_reader_node;
        return 1;
    };
    if ( not $okay ) {
        my $error = $@ || 'unknown error';
        $self->stderr("WARNING: register_reader_node failed: $error");
        $self->close_filehandle;
        return 'try again';
    }
    $self->init_connect;
    return $rv;
}

sub reconnect_inet {
    my $self   = shift;
    my $socket = $self->{fh};
    my $rv     = undef;
    if ( not $socket or not fileno $socket ) {
        if ( $self->{flags} & TK_SYNC ) {
            die 'FAILED: TK_SYNC not supported';
        }
        else {
            if ( defined $self->{inet_aton_serial}
                and not $self->{address} )
            {
                if ( $Tachikoma::Inet_AtoN_Serial
                    == $self->{inet_aton_serial} )
                {
                    return 'try again' if ( $Tachikoma::Nodes{'Inet_AtoN'} );
                }
                elsif ( not $Tachikoma::Nodes{'Inet_AtoN'} ) {
                    $self->stderr('WARNING: restarting Inet_AtoN');
                }
            }
            $self->dns_lookup;
            $rv = 'try again';
        }
        $self->{high_water_mark}  = 0;
        $self->{largest_msg_sent} = 0;
        $self->{latency_score}    = undef;
    }
    return $rv;
}

sub dns_lookup {
    my $self = shift;
    #
    # When in doubt, use brute force--let's just fork our own resolver.
    # This turns out to perform quite well:
    #
    my $secure = Tachikoma->configuration->{secure_level};
    return $self->close_filehandle('reconnect')
        if ( defined $secure and $secure == 0 );
    my $sink =
           $Tachikoma::Nodes{'_command_interpreter'}
        || $Tachikoma::Nodes{'_router'}
        || die q(FAILED: couldn't find a suitable sink);
    my $inet_aton = $Tachikoma::Nodes{'Inet_AtoN'};
    my $wait      = undef;
    if ( not $inet_aton ) {
        if ( Tachikoma->get_pid("Inet_AtoN.$<") ) {
            $inet_aton =
                Tachikoma::Nodes::Socket->unix_client("/tmp/Inet_AtoN.$<");
            $inet_aton->name('Inet_AtoN');
            $inet_aton->sink($sink);
            $wait = 1;
        }
        else {
            my $job_controller = $Tachikoma::Nodes{'jobs'};
            if ( not $job_controller ) {
                require Tachikoma::Nodes::JobController;
                $job_controller = Tachikoma::Nodes::JobController->new;
                $job_controller->name('jobs');
                $job_controller->sink($sink);
            }
            $inet_aton = $Tachikoma::Nodes{'Inet_AtoN'};
            if ( not $inet_aton ) {
                $inet_aton =
                    $job_controller->start_job( { type => 'Inet_AtoN' } );
                $Tachikoma::Inet_AtoN_Serial++;
            }
            $self->{inet_aton_serial} = $Tachikoma::Inet_AtoN_Serial;
        }
    }
    #
    # Send the hostname to our Inet_AtoN job.
    # When it sends the reply, we pick it up with fill_buffer_init().
    #
    # see also inet_client_async(), fill_buffer_init(), init_socket(),
    #      and reconnect()
    #
    if ( not $wait ) {
        my $message = Tachikoma::Message->new;
        $message->[TYPE]    = TM_REQUEST;
        $message->[FROM]    = join q(/), '_responder', $self->{name};
        $message->[PAYLOAD] = $self->{hostname};
        $inet_aton->fill($message);
        $self->{fill}    = $self->{fill_modes}->{init};
        $self->{address} = undef;
    }
    return;
}

sub dump_config {    ## no critic (ProhibitExcessComplexity)
    my $self     = shift;
    my $response = q();
    if ( $self->{type} eq 'listen' ) {
        $response = $self->{filename} ? 'listen_unix' : 'listen_inet';
        if ( ref $self eq 'Tachikoma::Nodes::STDIO' ) {
            $response .= ' --io';
        }
        $response .= ' --delegate=' . $self->{delegates}->{tachikoma}
            if ( $self->{delegates}->{tachikoma} );
        if ( $self->{filename} ) {
            $response .= ' --perms=' . $self->{fileperms}
                if ( $self->{fileperms} );
            $response .= ' --gid=' . $self->{filegid} if ( $self->{filegid} );
            $response .= " $self->{filename} $self->{name}\n";
        }
        else {
            $response .= " $self->{name}\n";
        }
        my $registrations = $self->{registrations};
        for my $event_type ( keys %{$registrations} ) {
            for my $path ( keys %{ $registrations->{$event_type} } ) {
                $response .= "register $self->{name} $path $event_type\n"
                    if ( not $registrations->{$event_type}->{$path} );
            }
        }
    }
    elsif ( $self->{type} eq 'connect' ) {
        $response = $self->{filename} ? 'connect_unix' : 'connect_inet';
        if ( ref $self eq 'Tachikoma::Nodes::STDIO' ) {
            $response .= ' --io';
            $response .= ' --reconnect' if ( $self->{on_EOF} eq 'reconnect' );
        }
        if ( $self->{filename} ) {
            $response .= " $self->{filename} $self->{name}\n";
        }
        else {
            $response .= " $self->{hostname}";
            $response .= ":$self->{port}"
                if ( $self->{port} != DEFAULT_PORT );
            $response .= " $self->{name}"
                if ( $self->{name} ne $self->{hostname} );
            $response .= "\n";
        }
    }
    else {
        $response = $self->SUPER::dump_config;
    }
    return $response;
}

sub sink {
    my ( $self, @args ) = @_;
    my $rv = $self->SUPER::sink(@args);
    if (    @args
        and $self->{type} eq 'connect'
        and not length $self->{address}
        and not length $self->{filename} )
    {
        if ( $self->{name} ) {
            $self->dns_lookup if ( $self->{sink} );
        }
        else {
            $self->stderr('ERROR: async connections must be named');
            $self->remove_node;
        }
    }
    return $rv;
}

sub set_drain_buffer {
    my $self = shift;
    $self->{drain_buffer} = \&drain_buffer_normal;
    return;
}

sub parent {
    my $self = shift;
    if (@_) {
        $self->{parent} = shift;
    }
    return $self->{parent};
}

sub hostname {
    my $self = shift;
    if (@_) {
        $self->{hostname} = shift;
    }
    return $self->{hostname};
}

sub address {
    my $self = shift;
    if (@_) {
        $self->{address} = shift;
    }
    return $self->{address};
}

sub port {
    my $self = shift;
    if (@_) {
        $self->{port} = shift;
    }
    return $self->{port};
}

sub filename {
    my $self = shift;
    if (@_) {
        $self->{filename} = shift;
    }
    return $self->{filename};
}

sub fileperms {
    my $self = shift;
    if (@_) {
        $self->{fileperms} = shift;
    }
    return $self->{fileperms};
}

sub filegid {
    my $self = shift;
    if (@_) {
        $self->{filegid} = shift;
    }
    return $self->{filegid};
}

sub auth_challenge {
    my $self = shift;
    if (@_) {
        $self->{auth_challenge} = shift;
    }
    return $self->{auth_challenge};
}

sub auth_timestamp {
    my $self = shift;
    if (@_) {
        $self->{auth_timestamp} = shift;
    }
    return $self->{auth_timestamp};
}

sub auth_complete {
    my $self = shift;
    if (@_) {
        $self->{auth_complete} = shift;
    }
    return $self->{auth_complete};
}

sub scheme {
    my $self = shift;
    if (@_) {
        my $scheme = shift;
        die "invalid scheme: $scheme\n"
            if ($scheme ne 'rsa'
            and $scheme ne 'rsa-sha256'
            and $scheme ne 'ed25519' );
        if ( $scheme eq 'ed25519' ) {
            die "Ed25519 not supported\n" if ( not $USE_SODIUM );
            die "Ed25519 not configured\n"
                if ( not $self->{configuration}->{private_ed25519_key} );
        }
        $self->{scheme} = $scheme;
    }
    return $self->{scheme};
}

sub delegates {
    my $self = shift;
    if (@_) {
        $self->{delegates} = shift;
    }
    return $self->{delegates};
}

sub last_upbeat {
    my $self = shift;
    if (@_) {
        $self->{last_upbeat} = shift;
    }
    return $self->{last_upbeat};
}

sub last_downbeat {
    my $self = shift;
    if (@_) {
        $self->{last_downbeat} = shift;
    }
    return $self->{last_downbeat};
}

sub latency_score {
    my $self = shift;
    if (@_) {
        $self->{latency_score} = shift;
    }
    return $self->{latency_score};
}

sub inet_aton_serial {
    my $self = shift;
    if (@_) {
        $self->{inet_aton_serial} = shift;
    }
    return $self->{inet_aton_serial};
}

1;
