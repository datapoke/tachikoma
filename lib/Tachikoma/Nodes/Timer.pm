#!/usr/bin/perl
# ----------------------------------------------------------------------
# Tachikoma::Nodes::Timer
# ----------------------------------------------------------------------
#

package Tachikoma::Nodes::Timer;
use strict;
use warnings;
use Tachikoma::Node;
use Tachikoma::Message qw( TYPE FROM TO STREAM PAYLOAD TM_BYTESTREAM );
use parent             qw( Tachikoma::Node );

use version; our $VERSION = qv('v2.0.197');

sub new {
    my $class = shift;
    my $self  = $class->SUPER::new;
    $self->{type}                  = 'timer';
    $self->{id}                    = undef;
    $self->{stream}                = undef;
    $self->{timer_interval}        = undef;
    $self->{timer_is_active}       = undef;
    $self->{fire_cb}               = \&fire_cb;
    $self->{registrations}->{FIRE} = {};
    bless $self, $class;
    return $self;
}

sub arguments {
    my $self = shift;
    if (@_) {
        my $class = ref $self;
        die "ERROR: $class needs its own arguments method"
            . " to be a subclass of Timer\n"
            if ( $class ne 'Tachikoma::Nodes::Timer' );
        $self->{arguments} = shift;
        my ( $time, $oneshot ) = split q( ), $self->{arguments}, 2;
        $self->set_timer( $time, $oneshot );
    }
    return $self->{arguments};
}

sub fire_cb {
    my $self = shift;
    $self->{timer_is_active} = undef
        if ( ( $self->{timer_is_active} // q() ) ne 'forever' );
    return if ( not $self->{sink} );
    $self->fire;
    return;
}

sub fire {
    my $self = shift;
    if ($self->{owner}
        or ( $self->{sink}
            and ref( $self->{sink} ) ne
            'Tachikoma::Nodes::CommandInterpreter' )
        )
    {
        my $message = Tachikoma::Message->new;
        $message->[TYPE]    = TM_BYTESTREAM;
        $message->[FROM]    = $self->{name};
        $message->[TO]      = $self->{owner};
        $message->[STREAM]  = $self->{stream};
        $message->[PAYLOAD] = $Tachikoma::Right_Now . "\n";
        $self->{counter}++;
        $self->{sink}->fill($message);
    }
    $self->notify( 'FIRE', $Tachikoma::Right_Now );
    return;
}

sub set_timer {
    my $self    = shift;
    my $time    = shift;
    my $oneshot = shift;

    # die "ERROR: invalid time requested by $self->{name}\n"
    #     if ( defined $time and $time =~ m{[^\d.]} );
    if ( not $self->{id} ) {
        do {
            $self->{id} = Tachikoma->counter;
        } while ( exists $Tachikoma::Nodes_By_ID->{ $self->{id} } );
        $Tachikoma::Nodes_By_ID->{ $self->{id} } = $self;
    }
    if ( defined $time ) {
        $self->stop_timer
            if ( $self->{timer_is_active}
            and not defined $self->{timer_interval} );
        $Tachikoma::Event_Framework->set_timer( $self, $time, $oneshot );
    }
    elsif ( not defined $oneshot ) {
        $self->stop_timer
            if ( $self->{timer_is_active}
            and defined $self->{timer_interval} );
        $Tachikoma::Nodes{_router}->register( 'TIMER' => $self->{name} );
    }
    else {
        die "ERROR: can't oneshot without a time\n";
    }
    $self->{timer_interval}  = $time;
    $self->{timer_is_active} = $oneshot ? 'once' : 'forever';
    return;
}

sub remove_node {
    my $self = shift;
    $self->stop_timer if ( $self->{timer_is_active} );
    push @Tachikoma::Closing, sub {
        $self->stop_timer_and_remove_node;
    };
    return;
}

sub stop_timer_and_remove_node {
    my $self = shift;
    $self->stop_timer if ( $self->{timer_is_active} );
    delete( $Tachikoma::Nodes_By_ID->{ $self->{id} } )
        if ( defined $self->{id} );
    $self->{id} = undef;
    $self->SUPER::remove_node;
    return;
}

sub stop_timer {
    my $self           = shift;
    my $timer_interval = $self->{timer_interval};
    if ( defined $self->{timer_interval} ) {
        $Tachikoma::Event_Framework->stop_timer($self);
    }
    elsif ( $self->{name} ) {
        $Tachikoma::Nodes{_router}->unregister( 'TIMER' => $self->{name} );
    }
    $self->{timer_is_active} = undef;
    $self->{timer_interval}  = undef;
    return;
}

sub type {
    my $self = shift;
    if (@_) {
        $self->{type} = shift;
    }
    return $self->{type};
}

sub id {
    my $self = shift;
    if (@_) {
        $self->{id} = shift;
    }
    return $self->{id};
}

sub stream {
    my $self = shift;
    if (@_) {
        $self->{stream} = shift;
    }
    return $self->{stream};
}

sub timer_interval {
    my $self = shift;
    if (@_) {
        $self->{timer_interval} = shift;
    }
    return $self->{timer_interval};
}

sub timer_is_active {
    my $self = shift;
    if (@_) {
        $self->{timer_is_active} = shift;
    }
    return $self->{timer_is_active};
}

1;
