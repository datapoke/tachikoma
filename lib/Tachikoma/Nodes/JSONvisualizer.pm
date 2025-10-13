#!/usr/bin/perl
# ----------------------------------------------------------------------
# Tachikoma::Nodes::JSON_Visualizer
# ----------------------------------------------------------------------
#

package Tachikoma::Nodes::JSONvisualizer;
use strict;
use warnings;
use Tachikoma::Node;
use Tachikoma::Nodes::HTTP_Responder qw( log_entry cached_strftime );
use Tachikoma::Message               qw(
    TYPE FROM TO STREAM PAYLOAD TM_BYTESTREAM TM_STORABLE TM_EOF
);
use JSON;
use parent qw( Tachikoma::Node );

use version; our $VERSION = qv('v2.0.314');

sub new {
    my $class = shift;
    my $self  = $class->SUPER::new;
    $self->{full_cache}  = [];
    $self->{brief_cache} = [];
    $self->{last_update} = 0;
    bless $self, $class;
    return $self;
}

sub arguments {
    my $self = shift;
    if (@_) {
        $self->{arguments} = shift;
        my $pattern = $self->{arguments} || q(.);
        $self->{pattern} = qr{$pattern};
    }
    return $self->{arguments};
}

sub fill {
    my $self    = shift;
    my $message = shift;
    return if ( not $message->[TYPE] & TM_STORABLE );
    my $path    = $message->payload->{path};
    my $content = undef;
    $path =~ s{^/+}{};
    if ( $path eq 'brief' ) {
        $content = $self->gather_node_information('brief');
    }
    else {
        $content = $self->gather_node_information('full');
    }
    $self->send_http_response( $message, $content );
    $self->{counter}++;
    log_entry( $self, 200, $message );
    return;
}

sub gather_node_information {
    my $self    = shift;
    my $mode    = shift;
    my $content = undef;
    if ( $self->{last_update} > $Tachikoma::Now - 5 ) {
        if ( $mode eq 'full' ) {
            $content = $self->full_cache;
        }
        else {
            $content = $self->brief_cache;
        }
    }
    else {
        $content = $self->_gather_node_information($mode);
    }
    return $content;
}

sub _gather_node_information {
    my $self        = shift;
    my $mode        = shift;
    my %by_name     = ();
    my @full_table  = ();
    my @brief_table = ();
    my $content     = undef;
    my $ignore      = $self->{arguments};
    my %ids         = ();
    my $id          = 0;

    for my $name ( sort keys %Tachikoma::Nodes ) {
        my $node = $Tachikoma::Nodes{$name};
        next
            if ( $ignore
            and length( $node->{parent} )
            and $node->{parent} =~ m{$ignore} );
        $ids{$name}     = $id++;
        $by_name{$name} = {
            sink    => -1,
            edge    => -1,
            owner   => {},
            counter => $node->{counter} ? $node->{counter} : 0,
        };
    }
    for my $name ( sort keys %Tachikoma::Nodes ) {
        my $node = $Tachikoma::Nodes{$name};
        next
            if ( $ignore
            and length( $node->{parent} )
            and $node->{parent} =~ m{$ignore} );
        my $full_row = $by_name{$name};
        $full_row->{name} = $name;
        $full_row->{sink} = $ids{ $node->{sink}->{name} }
            if ( $node->{sink} );
        $full_row->{edge} = $ids{ $node->{edge}->{name} }
            if ( $node->{edge} );
        my $node_owner = $node->owner;
        $node_owner = length($node_owner) ? [$node_owner] : []
            if ( not ref $node_owner );
        for my $path ( @{$node_owner} ) {
            next if ( not length $path );
            my @next = split m{/}, $path;
            while ( my $child = shift @next ) {
                last if ( not exists $ids{$child} );
                $by_name{$name}->{owner}->{ $ids{$child} } = 1;
                $name = $child;
            }
        }
        push @full_table, $full_row;
    }
    for my $full_row (@full_table) {
        $full_row->{owner} = [ keys %{ $full_row->{owner} } ];
        my $brief_row = { %{$full_row} };
        delete $brief_row->{name};
        push @brief_table, $brief_row;
    }
    my $full_json  = encode_json( \@full_table );
    my $brief_json = encode_json( \@brief_table );
    $self->full_cache( \$full_json );
    $self->brief_cache( \$brief_json );
    $self->last_update($Tachikoma::Now);
    if ( $mode eq 'full' ) {
        $content = \$full_json;
    }
    else {
        $content = \$brief_json;
    }
    return $content;
}

sub send_http_response {
    my ( $self, $message, $content ) = @_;
    my $response = Tachikoma::Message->new;
    $response->[TYPE]    = TM_BYTESTREAM;
    $response->[TO]      = $message->[FROM];
    $response->[STREAM]  = $message->[STREAM];
    $response->[PAYLOAD] = join q(),
        "HTTP/1.1 200 OK\n",
        'Date: ', cached_strftime(), "\n",
        "Server: Tachikoma\n",
        "Connection: close\n",
        "Content-Type: application/json\n",
        'Content-Length: ',
        length( ${$content} ),
        "\n\n",
        ${$content};
    $self->{sink}->fill($response);
    $response         = Tachikoma::Message->new;
    $response->[TYPE] = TM_EOF;
    $response->[TO]   = $message->[FROM];
    $self->{sink}->fill($response);
    return;
}

sub full_cache {
    my $self = shift;
    if (@_) {
        $self->{full_cache} = shift;
    }
    return $self->{full_cache};
}

sub brief_cache {
    my $self = shift;
    if (@_) {
        $self->{brief_cache} = shift;
    }
    return $self->{brief_cache};
}

sub last_update {
    my $self = shift;
    if (@_) {
        $self->{last_update} = shift;
    }
    return $self->{last_update};
}

1;
