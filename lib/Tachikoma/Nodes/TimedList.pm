#!/usr/bin/perl
# ----------------------------------------------------------------------
# Tachikoma::Nodes::TimedList
# ----------------------------------------------------------------------
#

package Tachikoma::Nodes::TimedList;
use strict;
use warnings;
use Tachikoma::Nodes::List;
use Tachikoma::Message qw( TM_BYTESTREAM );
use parent             qw( Tachikoma::Nodes::List );

use version; our $VERSION = qv('v2.0.368');

sub arguments {
    my $self = shift;
    if (@_) {
        $self->SUPER::arguments(@_);
        $self->set_timer;
    }
    return $self->{arguments};
}

sub add_item {
    my $self = shift;
    my $item = shift;
    $self->remove_item($item);
    return $self->SUPER::add_item($item);
}

sub remove_item {
    my $self = shift;
    my $item = shift;
    $item .= "\n" if ( substr( $item, -1, 1 ) ne "\n" );
    my $entry    = ( split q( ), $item, 2 )[1];
    my @new_list = ();
    for my $old_item ( @{ $self->{list} } ) {
        next if ( $old_item =~ m{^\d+ $entry$} );
        push @new_list, $old_item;
    }
    $self->{list} = \@new_list;
    return;
}

sub fire {
    my $self  = shift;
    my @keep  = ();
    my $dirty = undef;
    for my $item ( @{ $self->{list} } ) {
        my ( $timestamp, $entry ) = split q( ), $item, 2;
        if ( $timestamp =~ m{\D} or $timestamp < $Tachikoma::Now ) {
            $self->notify( 'RM' => "rm $item" );
            $dirty = 1;
            next;
        }
        push @keep, $item;
    }
    if ($dirty) {
        $self->{list} = \@keep;
        $self->write_list;
    }
    return;
}

1;
