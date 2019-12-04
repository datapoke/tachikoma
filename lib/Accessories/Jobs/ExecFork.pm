#!/usr/bin/perl
# ----------------------------------------------------------------------
# Accessories::Jobs::ExecFork
# ----------------------------------------------------------------------
#
# $Id: ExecFork.pm 38388 2019-12-04 08:32:30Z chris $
#

package Accessories::Jobs::ExecFork;
use strict;
use warnings;
use Tachikoma::Job;
use Tachikoma::Message qw( TM_BYTESTREAM );
use IPC::Open3;
use parent qw( Tachikoma::Job );

use version; our $VERSION = qv('v2.0.700');

sub initialize_graph {
    my $self = shift;
    $self->connector->sink($self);
    $self->sink( $self->router );
    untie *STDOUT;
    untie *STDERR;
    if ( $self->owner ) {
        local $SIG{PIPE} = sub { die $! };
        my ( $read, $write );
        open3( $write, $read, $read, $self->arguments ) or die $!;
        local $/ = undef;
        my $output = <$read>;
        close $read or die $!;
        my $message = Tachikoma::Message->new;
        $message->type(TM_BYTESTREAM);
        $message->stream( $self->arguments );
        $message->payload($output);
        $self->SUPER::fill($message);
        exit 0;
    }
    else {
        die 'ERROR: invalid request';
    }
    return;
}

1;
