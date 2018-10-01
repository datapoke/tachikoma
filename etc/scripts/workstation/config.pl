#!/usr/bin/perl
use strict;
use warnings;
require 'config.pl';

sub workstation_header {
    print <<EOF;
v2
var hostname = `hostname -s`;
var home     = `echo ~`;
var services = "<home>/.tachikoma/services";
include services/config.tsl

# listen_inet 127.0.0.1:4230
make_node CommandInterpreter hosts
make_node JobController      jobs
command jobs start_job Tail  local_server_log /var/log/tachikoma/tachikoma-server.log
make_node Ruleset            server_log:ruleset
make_node Tee                server_log:tee
make_node Tee                server_log
make_node Tee                error_log:tee
make_node Tee                error_log
make_node Ruleset            local_system_log:ruleset
make_node Ruleset            system_log:ruleset
make_node Tee                system_log:tee
make_node Tee                system_log
make_node Tee                silc_dn:tee
make_node Tee                http_log
make_node Null               null
make_node Echo               echo
make_node Scheduler          scheduler

cd server_log:ruleset:config
  add  100 deny where payload=.* FROM: .* ID: "(tachikoma\@<hostname>)" COMMAND: .*
  add  200 deny where payload=silo .* pub .* user .* addr .* is rfc1918
  add  999 copy to error_log:tee where payload="WARNING:|ERROR:|FAILED:|TRAP:|COMMAND:|CircuitTester:|reconnect:"
  add 1000 redirect to server_log:tee
cd ..

cd local_system_log:ruleset:config
  add 100 allow where payload=sudo
  add 1000 deny
cd ..

cd system_log:ruleset:config
  add 200  deny where payload=ipmi0: KCS
  add 1000 redirect to system_log:tee
cd ..

command jobs start_job Transform server_log:color '/usr/local/etc/tachikoma/LogColor.conf' 'Log::Color::filter(\@_)'
command jobs start_job Transform error_log:color  '/usr/local/etc/tachikoma/LogColor.conf' 'Log::Color::filter(\@_)'
command jobs start_job Transform system_log:color '/usr/local/etc/tachikoma/LogColor.conf' 'Log::Color::filter(\@_)'

connect_node system_log:color         system_log
connect_node system_log:tee           system_log:color
connect_node local_system_log:ruleset system_log:ruleset
connect_node error_log:color          error_log
connect_node error_log:tee            error_log:color
connect_node server_log:color         server_log
connect_node server_log:tee           server_log:color
connect_node local_server_log         server_log:ruleset

EOF
}

sub workstation_benchmarks {
    print <<EOF;


# benchmarks
listen_inet       127.0.0.1:5000
listen_inet       127.0.0.1:5001
listen_inet --io  127.0.0.1:6000
connect_edge 127.0.0.1:5000 null
connect_edge 127.0.0.1:6000 null
on 127.0.0.1:5001 authenticated {
    make_node Null benchmark:timer 0 512 100;
    connect_sink benchmark:timer <1>;
}
on 127.0.0.1:5001 EOF rm benchmark:timer
on 127.0.0.1:6000 connected {
    make_node Null benchmark:timer 0 16 65000;
    connect_sink benchmark:timer <1>;
}
on 127.0.0.1:6000 EOF rm benchmark:timer

EOF
}

sub workstation_partitions {
    print <<EOF;


# partitions
make_node Partition scratch:log --filename=/logs/scratch.log --segment_size=(32 * 1024 * 1024)
make_node Partition offset:log  --filename=/logs/offset.log  --segment_size=(256 * 1024)
make_node Consumer scratch:consumer --partition=scratch:log --offsetlog=offset:log

EOF
}

sub workstation_services {
    print <<EOF;


# services
command jobs  run_job Shell <services>/hubs.tsl
command hosts connect_inet localhost:<tachikoma.hubs.port>     hubs:service

command jobs  run_job Shell <services>/indexers.tsl
command hosts connect_inet localhost:<tachikoma.indexers.port> indexers:service

command jobs  run_job Shell <services>/tables.tsl
command hosts connect_inet localhost:<tachikoma.tables.port>   tables:service

command jobs  run_job Shell <services>/engines.tsl
command hosts connect_inet localhost:5499                      engines:service

command jobs  run_job Shell <services>/hunter.tsl
command hosts connect_inet localhost:<tachikoma.hunter.port>   hunter:service



# ingest server logs
connect_node server_log:tee indexers:service/server_log

EOF
}

sub workstation_topic_top {
    print <<EOF;


# topic top
command jobs start_job CommandInterpreter topic_top
cd topic_top
  make_node Tee             topic_top:tee
  make_node ClientConnector topic_top:client_connector topic_top:tee
  make_node CommandInterpreter clients
  cd clients
    listen_inet 127.0.0.1:4381
    register 127.0.0.1:4381 topic_top:client_connector authenticated
    listen_inet 127.0.0.1:4391
    connect_node 127.0.0.1:4391 topic_top:tee
  cd ..
  secure 3
cd ..

EOF
}

sub workstation_sound_effects {
    print <<EOF;


# sound effects
make_node MemorySieve AfPlay:sieve     1
make_node JobFarmer   AfPlay           4 AfPlay
make_node MemorySieve CozmoAlert:sieve 1
make_node JobFarmer   CozmoAlert       1 CozmoAlert
make_node Function server_log:sounds '{
    local sound = "";
    # if (<1> =~ "\\sWARNING:\\s")    [ sound = Tink;                    ]
    if (<1> =~ "\\sERROR:\\s(.*)")  [ sound = Tink;   cozmo_alert <_1> ]
    elsif (<1> =~ "\\sFAILURE:\\s") [ sound = Sosumi;                  ]
    elsif (<1> =~ "\\sCOMMAND:\\s") [ sound = Hero;                    ];
    if (<sound>) { afplay { get_sound <sound> } };
}'
make_node Function silc:sounds '{
    local sound = Pop;
    if (<1> =~ "\\bchris\\b(?!>)") [ sound = Glass ];
    afplay { get_sound <sound> };
}'
command AfPlay     lazy on
command CozmoAlert lazy on
connect_node CozmoAlert       null
connect_node CozmoAlert:sieve CozmoAlert:load_balancer
connect_node AfPlay           null
connect_node AfPlay:sieve     AfPlay:load_balancer
connect_node server_log:tee   server_log:sounds
connect_node silc_dn:tee      silc:sounds

EOF
}

sub workstation_http_server {
    print <<EOF;


# http server
command jobs start_job CommandInterpreter http
cd http
  listen_inet --io 127.0.0.1:4242
  make_node HTTP_Responder    responder /tmp/http 4242
  make_node HTTP_Timeout
  make_node Echo              http:log
  make_node HTTP_Route        root
  make_node HTTP_Auth         root:auth <home>/Sites/.htpasswd tachikoma-tools
  make_node HTTP_File         root:dir  <home>/Sites
  make_node JobFarmer         CGI       4 CGI /usr/local/etc/tachikoma/CGI.conf /tmp/http
  command CGI  autokill on
  command CGI  lazy on
  command root add_path /              root:dir
  command root add_path /cgi-bin       CGI
  command root add_path /debug/capture http:log
  connect_node http:log     _parent/http_log
  connect_node root:auth    root
  connect_node responder    root:auth
  connect_sink 127.0.0.1:4242 responder

  # listen_inet --io 127.0.0.1:4243
  # make_node HTTP_Responder    proxy:responder /tmp/proxy 4243
  # make_node JobFarmer         LWP             4 LWP 90 /tmp/proxy
  # connect_node proxy:responder LWP
  # connect_sink 127.0.0.1:4243    proxy:responder
  secure 3
cd ..

EOF
}

sub workstation_hosts {
    print <<EOF;
cd hosts
  connect_inet --use-ssl tachikoma:4231
  connect_inet --use-ssl tachikoma:4232 server_logs
  connect_inet --use-ssl tachikoma:4233 system_logs
  connect_inet --use-ssl tachikoma:4234 silc_dn
cd ..

connect_node silc_dn                  silc_dn:tee
connect_node system_logs              system_log:ruleset
connect_node server_logs              server_log:ruleset

EOF
}

1;
