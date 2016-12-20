#!/usr/bin/env bash

# This automates setting up exactly our standard SMC cluster.
# Do `k get services` 2 minutes after on both namespaces to find
# out the ip addresses to put in cloudflare.

set -e
set -v

# create the namespace
./control.py namespace test

# start haproxy
cd ../haproxy/ && ./control.py load-ssl ~/secrets/haproxy/ && ./control.py run -r 1

# setup rethinkdb to point to outside db cluster and know password
cd ../rethinkdb && ./control.py external db0 db1 db2 db3 db4 db5 && ./control.py load-password ~/secrets/rethinkdb/

# load passwords into hub and start
cd ../smc-hub/ && ./control.py load-sendgrid ~/secrets/sendgrid/ && ./control.py load-zendesk ~/secrets/zendesk/ && ./control.py run -r 1

# start static nginx server
cd ../smc-webapp-static/ && ./control.py run -r 1

cd ../cluster

# create the namespace
./control.py namespace prod

# create the cluster manager deployment
cd manager
./control.py run
cd ..

# start haproxy
cd ../haproxy/ && ./control.py load-ssl ~/secrets/haproxy/ && ./control.py run -r 3 && ./control.py autoscale --min=3 --max=3

# setup rethinkdb to point to outside db cluster and know password
cd ../rethinkdb && ./control.py external db0 db1 db2 db3 db4 db5 && ./control.py load-password ~/secrets/rethinkdb/

# load passwords into hub and start
cd ../smc-hub/ && ./control.py load-sendgrid ~/secrets/sendgrid/ && ./control.py load-zendesk ~/secrets/zendesk/ && ./control.py run -r 10 && ./control.py autoscale --min=10 --max=10

# start static nginx server
cd ../smc-webapp-static/ && ./control.py run -r 3  && ./control.py autoscale --min=3 --max=3

# start project manager
cd ../smc-project/manager
./control.py run
cd ..

# TODOs
# start disk-space watcher, which automatically increases disk space.

# start cluster manager, which ensures pre-emptible nodes restart quickly.

