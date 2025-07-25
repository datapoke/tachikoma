#!/usr/bin/perl
# ----------------------------------------------------------------------
# Tachikoma::Nodes::Responder
# ----------------------------------------------------------------------
#
#  - duct tape everything together at the last minute
#

package Tachikoma::Nodes::Responder;
use strict;
use warnings;
use Tachikoma::Node;
use Tachikoma::Message qw(
    TYPE FROM TO ID STREAM PAYLOAD
    TM_BYTESTREAM TM_COMMAND TM_PERSIST TM_RESPONSE TM_ERROR
);
use Tachikoma::Command;
use parent qw( Tachikoma::Node );

use version; our $VERSION = qv('v2.0.280');

sub new {
    my $class = shift;
    my $self  = $class->SUPER::new;
    $self->{last_buffer} = undef;
    $self->{ignore}      = undef;
    $self->{shell}       = undef;
    bless $self, $class;
    return $self;
}

sub arguments {
    my $self = shift;
    if (@_) {
        $self->{arguments} = shift;
        $self->last_buffer( $self->{arguments} );
    }
    return $self->{arguments};
}

sub fill {
    my $self    = shift;
    my $message = shift;
    my $type    = $message->[TYPE];
    my $shell   = $self->{shell};
    $self->{counter}++;
    if (    $message->[ID]
        and $shell
        and $shell->{callbacks}->{ $message->[ID] } )
    {
        if ( $type & TM_COMMAND ) {
            my $command = Tachikoma::Command->new( $message->[PAYLOAD] );
            $shell->callback(
                $message->[ID],
                {   from    => $message->[FROM],
                    event   => $command->{name},
                    payload => $command->{payload},
                    error   => $type & TM_ERROR
                }
            );
        }
        else {
            $shell->callback(
                $message->[ID],
                {   from    => $message->[FROM],
                    event   => $message->[STREAM] || 'unknown',
                    payload => $message->[PAYLOAD],
                    error   => $type & TM_ERROR
                }
            );
        }
        return;
    }
    elsif ( $type & TM_RESPONSE and $message->[FROM] eq 'Inet_AtoN' ) {
        my $name = $message->[TO];
        if ( $Tachikoma::Nodes{$name} ) {
            #
            # A connection is starting up, and our Inet_AtoN job is
            # sending us the results of the DNS lookup.
            # see also inet_client_async(), dns_lookup(), and init_socket()
            # in Tachikoma::Nodes::Socket
            #
            my $node   = $Tachikoma::Nodes{$name};
            my $secure = Tachikoma->configuration->{secure_level};
            return $node->close_filehandle('reconnect')
                if ( defined $secure and $secure == 0 );
            my $okay = eval {
                $node->init_socket( $message->[PAYLOAD] );
                return 1;
            };
            if ( not $okay ) {
                my $error = $@ || 'unknown error';
                $node->stderr("ERROR: init_socket failed: $error");
                $node->close_filehandle('reconnect');
            }
        }
        return;
    }
    if ( $self->{owner} ) {
        $message->[TYPE] ^= TM_PERSIST if ( $type & TM_PERSIST );
        $self->SUPER::fill($message);
    }
    if ( $type & TM_PERSIST and not $self->{ignore} ) {
        my $response = Tachikoma::Message->new;
        $response->[TYPE]    = TM_PERSIST | TM_RESPONSE;
        $response->[FROM]    = $self->{name};
        $response->[TO]      = $self->get_last_buffer($message);
        $response->[ID]      = $message->[ID];
        $response->[STREAM]  = $message->[STREAM];
        $response->[PAYLOAD] = $type & TM_ERROR ? 'answer' : 'cancel';
        $Tachikoma::Nodes{_router}->fill($response);
    }
    return;
}

sub get_last_buffer {
    my $self        = shift;
    my $message     = shift;
    my $last_buffer = $self->{last_buffer};
    my $from        = $message->[FROM];
    if ($last_buffer) {
        if ( not $from =~ s{^.*?($last_buffer)}{$1}s ) {
            my $name = ( split m{/}, $last_buffer, 2 )[0];
            if ( $Tachikoma::Nodes{$name} ) {
                $from = $last_buffer;
            }
            else {
                # $last_buffer is probably intended only as a regex,
                # so warn and send the response back to the sender
                $self->stderr( q(WARNING: couldn't find last buffer for ),
                    $from );
            }
        }
    }
    return $from;
}

sub remove_node {
    my $self = shift;
    $self->shell(undef);
    $self->SUPER::remove_node;
    return;
}

sub last_buffer {
    my $self = shift;
    if (@_) {
        $self->{last_buffer} = shift;
    }
    return $self->{last_buffer};
}

sub ignore {
    my $self = shift;
    if (@_) {
        $self->{ignore} = shift;
    }
    return $self->{ignore};
}

sub shell {
    my $self = shift;
    if (@_) {
        $self->{shell} = shift;
    }
    return $self->{shell};
}

1;
