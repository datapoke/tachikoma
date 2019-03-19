#!/usr/bin/perl
# ----------------------------------------------------------------------
# Tachikoma::Nodes::Responder
# ----------------------------------------------------------------------
#
#  - duct tape everything together at the last minute
#
# $Id: Responder.pm 36778 2019-03-19 04:33:11Z chris $
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
    $self->{client}      = undef;
    $self->{ignore}      = undef;
    $self->{router}      = undef;
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
    my $rv      = undef;
    if (    $type & TM_COMMAND
        and ( $type & TM_RESPONSE or $type & TM_ERROR )
        and $message->[ID] )
    {
        my $shell = $self->{shell};
        if ( not $shell ) {
            $self->stderr('WARNING: unexpected command response with id');
            return;
        }
        my $command = Tachikoma::Command->new( $message->[PAYLOAD] );
        $shell->callback(
            $message->[ID],
            {   from    => $message->[FROM],
                event   => $command->{name},
                payload => $command->{payload},
                error   => $type & TM_ERROR
            }
        );
        delete $shell->callbacks->{ $message->[ID] };
        return;
    }
    if ( $self->{client} or $self->{owner} ) {
        $message->[TYPE] ^= TM_PERSIST if ( $type & TM_PERSIST );
        $rv = $self->SUPER::fill($message);
    }
    $self->{counter}++;
    return $rv if ( not $type & TM_PERSIST or $self->{ignore} );
    my $response = Tachikoma::Message->new;
    $response->[TYPE]    = TM_PERSIST | TM_RESPONSE;
    $response->[FROM]    = $self->{name};
    $response->[TO]      = $self->get_last_buffer($message);
    $response->[ID]      = $message->[ID];
    $response->[STREAM]  = $message->[STREAM];
    $response->[PAYLOAD] = $type & TM_ERROR ? 'answer' : 'cancel';

    # $self->stderr('sending response to ' . $response->[TO]);
    $self->router->fill($response);
    return $rv;
}

sub get_last_buffer {
    my $self        = shift;
    my $message     = shift;
    my $last_buffer = $self->{last_buffer};
    my $client      = $self->{client};
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
    elsif ( $client and $client eq 'tachikoma' ) {
        $from = ( split m{/}, $from, 2 )[1];
    }
    return $from;
}

sub remove_node {
    my $self = shift;
    $self->router(undef);
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

sub client {
    my $self = shift;
    if (@_) {
        $self->{client} = shift;
    }
    return $self->{client};
}

sub ignore {
    my $self = shift;
    if (@_) {
        $self->{ignore} = shift;
    }
    return $self->{ignore};
}

sub router {
    my $self = shift;
    if (@_) {
        $self->{router} = shift;
    }
    return $self->{router} || $self->{sink};
}

sub shell {
    my $self = shift;
    if (@_) {
        $self->{shell} = shift;
    }
    return $self->{shell};
}

1;
