#!/usr/bin/perl
# ----------------------------------------------------------------------
# sse-tail.cgi - Server-Sent Events streaming tail
# ----------------------------------------------------------------------
#

use strict;
use warnings;
use Tachikoma::Nodes::ConsumerBroker;
use Tachikoma::Message qw( ID TIMESTAMP );
use CGI;
use JSON -support_by_pp;

$| = 1;    # Autoflush

my $json = JSON->new;
$json->canonical(1);
$json->allow_blessed(1);

my $home   = ( getpwuid $< )[7];
my $config = Tachikoma->configuration;
$config->load_config_file(
    "$home/.tachikoma/etc/tachikoma.conf",
    '/usr/local/etc/tachikoma.conf',
);

my $broker_ids = undef;
if ($Tachikoma::Nodes::CGI::Config) {
    $broker_ids = $Tachikoma::Nodes::CGI::Config->{broker_ids};
}
$broker_ids ||= ['localhost:5501'];

my $cgi  = CGI->new;
my $path = $cgi->path_info;
$path =~ s(^/)();
my ( $topic, $location, $count ) = split m{/}, $path, 3;
die "no topic\n" if ( not length $topic );
$location ||= 'recent';
$count    ||= 100;

# Check for Last-Event-ID header (sent automatically by EventSource on reconnect)
# Format: comma-separated offsets per partition, e.g. "123,456,789"
my $last_event_id = $ENV{HTTP_LAST_EVENT_ID} // q();
if ( $last_event_id =~ m{^[\d,]+$} ) {
    $location = $last_event_id;
}

# SSE headers
print "Content-Type: text/event-stream\n";
print "Cache-Control: no-cache\n";
print "Connection: keep-alive\n";
print "X-Accel-Buffering: no\n";
print "\n";

CORE::state %groups;
$groups{$topic} //= Tachikoma::Nodes::ConsumerBroker->new($topic);
$groups{$topic}->broker_ids($broker_ids);
my $group      = $groups{$topic};
my $partitions = $group->get_partitions;

if ( not $partitions ) {
    print "event: error\n";
    print "data: no partitions for topic\n\n";
    exit;
}

# Initialize consumers with starting offset
my @offsets = ();
if ( $location =~ m{^\D} ) {
    $location = 'recent' if ( $location eq 'last' );
    push @offsets, $location for ( 0 .. keys %{$partitions} );
}
else {
    @offsets = split m{,}, $location;
}

for my $partition ( keys %{$partitions} ) {
    my $consumer = $group->consumers->{$partition}
        || $group->make_sync_consumer($partition);
    my $offset = $offsets[$partition] // 'recent';
    if ( $offset =~ m{^\d+$} ) {
        $consumer->next_offset($offset);
    }
    else {
        $consumer->default_offset($offset);
    }
}

my $last_heartbeat = time();
my $max_runtime    = 300;    # 5 minutes, then client reconnects
my $start_time     = time();

# Main streaming loop
while (1) {
    my @messages = ();

    # Check for sync errors
    if ( $group->sync_error ) {
        print STDERR $group->sync_error;
        print "event: error\n";
        print "data: sync error\n\n";
        last;
    }

    # Fetch from all partitions
    for my $partition ( keys %{$partitions} ) {
        my $consumer = $group->consumers->{$partition};
        next if ( not $consumer );

        # Fetch available messages
        my $batch = $consumer->fetch;
        push @messages, @{$batch} if ($batch);
    }

    # Sort by timestamp
    @messages = sort {
        join( q(:), $a->[TIMESTAMP], $a->[ID] ) cmp
            join( q(:), $b->[TIMESTAMP], $b->[ID] )
    } @messages;

    # Limit to $count most recent if we got a lot
    shift @messages while ( @messages > $count );

    # Emit SSE events for each message
    for my $message (@messages) {
        my $payload = $message->payload;

        # JSON encode if payload is a reference
        if ( ref $payload ) {
            $payload = $json->utf8->encode($payload);
        }

        # Build current offsets for resumption (comma-separated)
        my @current_offsets = ();
        for my $p ( sort { $a <=> $b } keys %{$partitions} ) {
            my $c = $group->consumers->{$p};
            push @current_offsets, $c ? $c->{offset} : 0;
        }
        my $event_id = join q(,), @current_offsets;

        # SSE data lines can't have bare newlines
        $payload =~ s/\r?\n/\ndata: /g;
        $payload =~ s/\ndata: $//;    # Remove trailing if ended with newline

        print "id: $event_id\n";
        print "data: $payload\n\n";
    }

    # Heartbeat every 30s to prevent idle timeout
    my $now = time();
    if ( $now - $last_heartbeat >= 30 ) {
        print ": keepalive\n\n";
        $last_heartbeat = $now;
    }

    # Exit after max_runtime to allow client to reconnect fresh
    if ( $now - $start_time >= $max_runtime ) {
        print "event: reconnect\n";
        print "data: max runtime reached\n\n";
        last;
    }

    # Sleep briefly if no messages to avoid busy-wait
    select( undef, undef, undef, 0.1 ) if ( not @messages );
}
