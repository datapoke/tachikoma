#!/usr/bin/perl
# ----------------------------------------------------------------------
# Tachikoma::Nodes::HTTP_Wrapper
# ----------------------------------------------------------------------
#

package Tachikoma::Nodes::HTTP_Wrapper;
use strict;
use warnings;
use Tachikoma::Nodes::Timer;
use Tachikoma::Nodes::HTTP_Responder qw( log_entry cached_strftime );
use Tachikoma::Message qw(
    TYPE FROM TO ID STREAM TIMESTAMP PAYLOAD
    TM_BYTESTREAM TM_STORABLE TM_ERROR TM_EOF
);
use CGI;
use parent qw( Tachikoma::Nodes::Timer );

use version; our $VERSION = qv('v2.0.314');

my $TIMEOUT = 900;
my $COUNTER = 0;

sub new {
    my $class = shift;
    my $self  = $class->SUPER::new;
    $self->{messages} = {};
    bless $self, $class;
    return $self;
}

sub arguments {
    my $self = shift;
    if (@_) {
        $self->{arguments} = shift;
    }
    return $self->{arguments};
}

sub fill {
    my $self    = shift;
    my $message = shift;
    if ( $message->[TYPE] & TM_STORABLE ) {
        $message->[ID] = $self->msg_counter;
        $self->{messages}->{ $message->[ID] } = $message;
        if ( not $self->{timer_is_active} ) {
            $self->set_timer;
        }
        my $cgi     = CGI->new( $message->payload->{query_string} );
        my $request = Tachikoma::Message->new;
        $request->[TYPE]    = TM_BYTESTREAM;
        $request->[FROM]    = $self->{name};
        $request->[TO]      = $self->{owner};
        $request->[STREAM]  = $cgi->param('stream');
        $request->[ID]      = $message->[ID];
        $request->[PAYLOAD] = $cgi->param('payload');
        $self->{sink}->fill($request);
    }
    else {
        $self->handle_response($message);
    }
    return;
}

sub handle_response {
    my $self         = shift;
    my $message      = shift;
    my $http_code    = 400;
    my $http_msg     = 'Bad Request';
    my $http_content = 'Bad Request';
    if ( $message->[TYPE] & TM_ERROR ) {
        $http_code    = 500;
        $http_msg     = 'Internal Server Error';
        $http_content = 'Internal Server Error';
    }
    elsif ( $message->[TYPE] & TM_BYTESTREAM ) {
        $http_code    = 200;
        $http_msg     = 'OK';
        $http_content = $message->[PAYLOAD];
        $http_content = "OK\n"
            if ( not length $http_content or $http_content !~ m{\S} );
    }
    my $queued = $self->{messages}->{ $message->[ID] };
    delete $self->{messages}->{ $message->[ID] };
    if ($queued) {
        $self->send_response( $queued, $http_code, $http_msg, $http_content );
    }
    return;
}

sub send_response {
    my ( $self, $queued, $http_code, $http_msg, $http_content ) = @_;
    my $response = Tachikoma::Message->new;
    $response->[TYPE]    = TM_BYTESTREAM;
    $response->[TO]      = $queued->[FROM];
    $response->[STREAM]  = $queued->[STREAM];
    $response->[PAYLOAD] = join q(),
        "HTTP/1.1 ${http_code} ${http_msg}\n",
        'Date: ', cached_strftime(), "\n",
        "Server: Tachikoma\n",
        "Connection: close\n",
        "Content-Type: text/html\n",
        'Content-Length: ',
        length($http_content),
        "\n\n",
        $http_content;
    $self->{sink}->fill($response);
    $response         = Tachikoma::Message->new;
    $response->[TYPE] = TM_EOF;
    $response->[TO]   = $queued->[FROM];
    $self->{sink}->fill($response);
    $self->{counter}++;
    log_entry( $self, $http_code, $queued );
    return;
}

sub fire {
    my $self     = shift;
    my $messages = $self->{messages};
    for my $message_id ( keys %{$messages} ) {
        my $timestamp = $messages->{$message_id}->[TIMESTAMP];
        delete $messages->{$message_id}
            if ( $Tachikoma::Now - $timestamp > $TIMEOUT );
    }
    if ( not keys %{$messages} ) {
        $self->stop_timer;
    }
    return;
}

sub messages {
    my $self = shift;
    if (@_) {
        $self->{messages} = shift;
    }
    return $self->{messages};
}

sub msg_counter {
    my $self = shift;
    $COUNTER = ( $COUNTER + 1 ) % $Tachikoma::Max_Int;
    return sprintf '%d:%010d', $Tachikoma::Now, $COUNTER;
}

1;
