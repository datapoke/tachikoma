#!/usr/bin/perl
# ----------------------------------------------------------------------
# Tachikoma::Nodes::Shutdown
# ----------------------------------------------------------------------
#

package Tachikoma::Nodes::Shutdown;
use strict;
use warnings;
use Tachikoma::Node;
use Tachikoma::Message qw( TYPE FROM TM_EOF );
use parent             qw( Tachikoma::Node );

use version; our $VERSION = qv('v2.0.280');

sub fill {
    my $self    = shift;
    my $message = shift or return;
    if ( $message->[TYPE] & TM_EOF ) {
        return if ( $message->[FROM] !~ m{_responder$|_stdin$} );
        return $self->shutdown_all_nodes;
    }
    $self->{sink}->fill($message) if ( $self->{sink} );
    return;
}

1;
