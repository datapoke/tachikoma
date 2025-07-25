#!/usr/bin/perl
# ----------------------------------------------------------------------
# Tachikoma::Nodes::BufferProbeToGraphite
# ----------------------------------------------------------------------
#

package Tachikoma::Nodes::BufferProbeToGraphite;
use strict;
use warnings;
use Tachikoma::Nodes::Timer;
use Tachikoma::Message qw( TYPE TIMESTAMP PAYLOAD TM_BYTESTREAM );
use parent             qw( Tachikoma::Nodes::Timer );

use version; our $VERSION = qv('v2.0.368');

my $DEFAULT_INTERVAL = 60;
my @FIELDS           = qw(
    buff_fills
    p_msg_sent
    msg_in_buf
);

# err_sent
# max_unanswered
# msg_rcvd
# msg_sent
# msg_unanswered
# resp_rcvd
# resp_sent

sub new {
    my $class = shift;
    my $self  = $class->SUPER::new;
    $self->{prefix} = 'hosts';
    $self->{output} = {};
    bless $self, $class;
    return $self;
}

sub arguments {
    my $self = shift;
    if (@_) {
        $self->{arguments} = shift;
        my ( $prefix, $seconds ) = split q( ), $self->{arguments}, 2;
        $self->{prefix} = $prefix if ( defined $prefix );
        $seconds ||= $DEFAULT_INTERVAL;
        $self->set_timer( $seconds * 1000 );
    }
    return $self->{arguments};
}

sub fill {
    my $self    = shift;
    my $message = shift;
    return if ( not $message->[TYPE] & TM_BYTESTREAM );
    my $output    = $self->{output};
    my $prefix    = $self->{prefix};
    my $timestamp = $message->[TIMESTAMP];
    for my $line ( split m{^}, $message->[PAYLOAD] ) {
        my $buffer    = { map { split m{:}, $_, 2 } split q( ), $line };
        my $hostname  = $buffer->{hostname}  or next;
        my $buff_name = $buffer->{buff_name} or next;
        $hostname  =~ s{[.].*}{};
        $buff_name =~ s{[^\w\d]+}{_}g;
        for my $field (@FIELDS) {
            my $key = join q(.),
                $prefix, $hostname, 'tachikoma',
                'buffers', $buff_name, $field;
            $output->{$key} = "$key $buffer->{$field} $timestamp\n";
        }
    }
    return;
}

sub fire {
    my $self   = shift;
    my @output = values %{ $self->output };
    while (@output) {
        my (@seg)    = splice @output, 0, 16;
        my $response = Tachikoma::Message->new;
        $response->type(TM_BYTESTREAM);
        $response->payload( join q(), @seg );
        $self->SUPER::fill($response);
    }
    $self->output( {} );
    return;
}

sub prefix {
    my $self = shift;
    if (@_) {
        $self->{prefix} = shift;
    }
    return $self->{prefix};
}

sub output {
    my $self = shift;
    if (@_) {
        $self->{output} = shift;
    }
    return $self->{output};
}

1;
