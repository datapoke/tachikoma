#!/usr/bin/perl
# ----------------------------------------------------------------------
# Tachikoma::Message
# ----------------------------------------------------------------------
#

package Tachikoma::Message;
use strict;
use warnings;
no warnings qw( uninitialized );    ## no critic (ProhibitNoWarnings)
use Data::Dumper;
use Storable qw( nfreeze thaw );
use POSIX    qw( strftime );
use vars     qw( @EXPORT_OK );
use parent   qw( Exporter );
@EXPORT_OK = qw(
    TYPE FROM TO ID STREAM TIMESTAMP PAYLOAD
    IS_UNTHAWED LAST_MSG_FIELD
    VECTOR_SIZE
    TM_BYTESTREAM TM_EOF TM_PING
    TM_COMMAND TM_RESPONSE TM_ERROR
    TM_INFO TM_PERSIST TM_STORABLE
    TM_COMPLETION TM_BATCH TM_KILLME
    TM_NOREPLY TM_HEARTBEAT TM_REQUEST
);

use version; our $VERSION = qv('v2.0.27');

$Data::Dumper::Indent   = 1;
$Data::Dumper::Sortkeys = 1;
$Data::Dumper::Useperl  = 1;

use constant {
    TYPE           => 0,
    FROM           => 1,
    TO             => 2,
    ID             => 3,
    STREAM         => 4,
    TIMESTAMP      => 5,
    PAYLOAD        => 6,
    IS_UNTHAWED    => 7,
    LAST_MSG_FIELD => 7,

    VECTOR_SIZE => 4,    # bytes (32-bit unsigned network int)

    TM_BYTESTREAM => oct 1,        #     1
    TM_EOF        => oct 2,        #     2
    TM_PING       => oct 4,        #     4
    TM_COMMAND    => oct 10,       #     8
    TM_RESPONSE   => oct 20,       #    16
    TM_ERROR      => oct 40,       #    32
    TM_INFO       => oct 100,      #    64
    TM_PERSIST    => oct 200,      #   128
    TM_STORABLE   => oct 400,      #   256
    TM_COMPLETION => oct 1000,     #   512
    TM_BATCH      => oct 2000,     #  1024
    TM_KILLME     => oct 4000,     #  2048
    TM_NOREPLY    => oct 10000,    #  4096
    TM_HEARTBEAT  => oct 20000,    #  8192
    TM_REQUEST    => oct 40000,    # 16384
};

sub new {    ## no critic (RequireArgUnpacking, RequireFinalReturn)
    bless [ 0, q(), q(), q(), q(), $Tachikoma::Now || time, q(), 1 ], $_[0];
}

# XXX:M
sub unpacked {    ## no critic (RequireArgUnpacking, RequireFinalReturn)
    bless [ unpack 'xxxx N n/a n/a n/a n/a N a*', ${ $_[1] } ], $_[0];
}

sub size {
    my $self = shift;
    return length ${ $self->packed };
}

sub type {
    my $self = shift;
    if (@_) {
        $self->[TYPE] = shift;
    }
    return $self->[TYPE];
}

sub from {
    my $self = shift;
    if (@_) {
        $self->[FROM] = shift;
    }
    return $self->[FROM];
}

sub to {
    my $self = shift;
    if (@_) {
        $self->[TO] = shift;
    }
    return $self->[TO];
}

sub id {
    my $self = shift;
    if (@_) {
        $self->[ID] = shift;
    }
    return $self->[ID];
}

sub stream {
    my $self = shift;
    if (@_) {
        $self->[STREAM] = shift;
    }
    return $self->[STREAM];
}

sub timestamp {
    my $self = shift;
    if (@_) {
        $self->[TIMESTAMP] = shift;
    }
    if ( not $self->[TIMESTAMP] ) {
        $self->[TIMESTAMP] = time;
    }
    return $self->[TIMESTAMP];
}

sub payload {
    my $self = shift;
    if (@_) {
        $self->[PAYLOAD]     = shift;
        $self->[IS_UNTHAWED] = 1;
    }
    elsif ( $self->[TYPE] & TM_STORABLE and not $self->[IS_UNTHAWED] ) {
        if ( $self->[PAYLOAD] ) {
            $self->[PAYLOAD] = thaw( $self->[PAYLOAD] );
        }
        $self->[IS_UNTHAWED] = 1;
    }
    return $self->[PAYLOAD];
}

# XXX:M
# sub packed {    ## no critic (RequireArgUnpacking)
#     if ( $_[0]->[TYPE] & TM_STORABLE and $_[0]->[IS_UNTHAWED] ) {
#         if ( $_[0]->[PAYLOAD] ) {
#             $_[0]->[PAYLOAD] = nfreeze( $_[0]->[PAYLOAD] );
#         }
#         $_[0]->[IS_UNTHAWED] = 0;
#     }
#     my $packed = pack 'xxxx N n/a* n/a* n/a* n/a* N a*', @{ $_[0] };
#     substr $packed, 0, VECTOR_SIZE, pack 'N', length($packed) - VECTOR_SIZE;
#     return \$packed;
# }

sub packed {    ## no critic (RequireArgUnpacking)
    if ( $_[0]->[TYPE] & TM_STORABLE and $_[0]->[IS_UNTHAWED] ) {
        if ( $_[0]->[PAYLOAD] ) {
            $_[0]->[PAYLOAD] = nfreeze( $_[0]->[PAYLOAD] );
        }
        $_[0]->[IS_UNTHAWED] = 0;
    }
    my $packed = pack 'xxxx N n/a* n/a* n/a* n/a* N a*', @{ $_[0] };
    substr $packed, 0, VECTOR_SIZE, pack 'N', length $packed;
    return \$packed;
}

sub as_string {
    my $self = shift;
    return Dumper(
        {   type      => $self->type_as_string,
            from      => $self->[FROM],
            to        => $self->[TO],
            id        => $self->[ID],
            stream    => $self->[STREAM],
            timestamp => strftime( '%F %T %Z', localtime $self->[TIMESTAMP] ),
            payload   => $self->payload,
        }
    );
}

sub type_as_string {
    my $self = shift;
    my $type = $self->[TYPE];
    my @out  = ();
    if ( $type & TM_BYTESTREAM ) { push @out, 'TM_BYTESTREAM'; }
    if ( $type & TM_EOF )        { push @out, 'TM_EOF'; }
    if ( $type & TM_PING )       { push @out, 'TM_PING'; }
    if ( $type & TM_COMMAND )    { push @out, 'TM_COMMAND'; }
    if ( $type & TM_RESPONSE )   { push @out, 'TM_RESPONSE'; }
    if ( $type & TM_ERROR )      { push @out, 'TM_ERROR'; }
    if ( $type & TM_INFO )       { push @out, 'TM_INFO'; }
    if ( $type & TM_PERSIST )    { push @out, 'TM_PERSIST'; }
    if ( $type & TM_STORABLE )   { push @out, 'TM_STORABLE'; }
    if ( $type & TM_COMPLETION ) { push @out, 'TM_COMPLETION'; }
    if ( $type & TM_BATCH )      { push @out, 'TM_BATCH'; }
    if ( $type & TM_KILLME )     { push @out, 'TM_KILLME'; }
    if ( $type & TM_NOREPLY )    { push @out, 'TM_NOREPLY'; }
    if ( $type & TM_HEARTBEAT )  { push @out, 'TM_HEARTBEAT'; }
    if ( $type & TM_REQUEST )    { push @out, 'TM_REQUEST'; }
    return join ' | ', @out;
}

1;
