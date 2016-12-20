#!/usr/bin/env python3

"""
Hub management script
"""

import os, shutil, sys, tempfile
join = os.path.join

# Boilerplate to ensure we are in the directory fo this path and make the util module available.
SCRIPT_PATH = os.path.split(os.path.realpath(__file__))[0]
sys.path.insert(0, os.path.abspath(os.path.join(SCRIPT_PATH, '..', 'util')))
os.chdir(SCRIPT_PATH)
import util

# For now in all cases, we just call the container the following; really it should
# maybe be smc-webapp-static#sha1hash, which makes switching between versions easy, etc.
NAME='smc-hub'

SECRETS = os.path.abspath(join(SCRIPT_PATH, '..', '..', 'data', 'secrets'))

def build(tag, rebuild, upgrade=False, commit=None):
    """
    Build Docker container by installing and building everything inside the container itself, and
    NOT using ../../static/ on host.
    """
    # First build smc-hub-base, which is generic install of ubuntu packages, so we should rarely
    # clear the cache for this.
    v = ['sudo', 'docker', 'build', '-t', '{name}-base'.format(name=NAME)]
    if upgrade:
        v.append("--no-cache")
    v.append(".")
    util.run(v, path=join(SCRIPT_PATH, 'image-base'))

    # Next build smc-hub, which depends on smc-hub-base.
    v = ['sudo', 'docker', 'build', '-t', tag]
    if commit:
        v.append("--build-arg")
        v.append("commit={commit}".format(commit=commit))
    if rebuild:  # will cause a git pull to happen
        v.append("--no-cache")
    v.append('.')
    util.run(v, path=join(SCRIPT_PATH,'image'))

def build_docker(args):
    if args.commit:
        args.tag += ('-' if args.tag else '') + args.commit[:6]
    tag = util.get_tag(args, NAME)
    build(tag, args.rebuild, args.upgrade, args.commit)
    if not args.local:
        util.gcloud_docker_push(tag)

def run_on_kubernetes(args):
    if args.test:
        rethink_cpu_request = hub_cpu_request = '10m'
        rethink_memory_request = hub_memory_request = '200Mi'
    else:
        hub_cpu_request = '500m'
        hub_memory_request = '1Gi'
        rethink_cpu_request = '500m'
        rethink_memory_request = '2Gi'


    util.ensure_secret_exists('sendgrid-api-key', 'sendgrid')
    util.ensure_secret_exists('zendesk-api-key',  'zendesk')
    args.local = False # so tag is for gcloud
    if args.replicas is None:
        args.replicas = util.get_desired_replicas(NAME, 2)
    tag = util.get_tag(args, NAME, build)

    opts = {
        'image_hub'              : tag,
        'replicas'               : args.replicas,
        'pull_policy'            : util.pull_policy(args),
        'min_read_seconds'       : args.gentle,
        'smc_db_hosts'           : args.database_nodes,
        'smc_db_pool'            : args.database_pool_size,
        'smc_db_concurrent_warn' : args.database_concurrent_warn,
        'hub_cpu_request'        : hub_cpu_request,
        'hub_memory_request'     : hub_memory_request,
        'rethink_cpu_request'    : rethink_cpu_request,
        'rethink_memory_request' : rethink_memory_request
    }

    if args.database_nodes == 'localhost':
        from argparse import Namespace
        ns = Namespace(tag=args.rethinkdb_proxy_tag, local=False)
        opts['image_rethinkdb_proxy'] = util.get_tag(ns, 'rethinkdb-proxy', build)
        filename = 'smc-hub-rethinkdb-proxy.template.yaml'
    else:
        filename = '{name}.template.yaml'.format(name=NAME)
    t = open(join('conf', filename)).read()
    with tempfile.NamedTemporaryFile(suffix='.yaml', mode='w') as tmp:
        r = t.format(**opts)
        #print(r)
        tmp.write(r)
        tmp.flush()
        util.update_deployment(tmp.name)

    if NAME not in util.get_services():
        util.run(['kubectl', 'expose', 'deployment', NAME])


def stop_on_kubernetes(args):
    util.stop_deployment(NAME)

def load_secret(name, args):
    path = args.path
    if not os.path.exists(path):
        os.makedirs(path)
    if not os.path.isdir(path):
        raise RuntimeError("path='{path}' must be a directory".format(path=path))
    file = join(path, name)
    if not os.path.exists(file):
        raise RuntimeError("'{file}' must exist".format(file=file))
    util.create_secret(name+'-api-key', file)

def status(args):
    # Get all pod names
    v = util.get_pods(run=NAME)
    print("Getting last %s lines of logs from %s pods"%(args.tail, len(v)))
    for x in v:
        lg = util.get_logs(x['NAME'], tail=args.tail, container='smc-hub').splitlines()
        blocked = concurrent = 0
        for w in lg:
            if 'BLOCKED for' in w:   # 2016-07-07T17:39:23.159Z - debug: BLOCKED for 1925ms
                b = int(w.split()[-1][:-2])
                blocked = max(blocked, b)
            if 'concurrent]' in w:   # 2016-07-07T17:41:16.226Z - debug: [1 concurrent] ...
                concurrent = max(concurrent, int(w.split()[3][1:]))
        x['blocked'] = blocked
        x['concurrent'] = concurrent
        bad = util.run("kubectl describe pod {name} |grep Unhealthy |tail -1 ".format(name=x['NAME']), get_output=True, verbose=False).splitlines()
        if len(bad) > 0:
            x['unhealthy'] = bad[-1].split()[1]
        else:
            x['unhealthy'] = ''
    print("%-30s%-12s%-12s%-12s%-12s%-12s"%('NAME', 'CONCURRENT', 'BLOCKED', 'UNHEALTHY', 'RESTARTS', 'AGE'))
    for x in v:
        print("%-30s%-12s%-12s%-12s%-12s%-12s"%(x['NAME'], x['concurrent'], x['blocked'], x['unhealthy'], x['RESTARTS'], x['AGE']))

if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description='Control deployment of {name}'.format(name=NAME))
    subparsers = parser.add_subparsers(help='sub-command help')

    sub = subparsers.add_parser('build', help='build docker image')
    sub.add_argument("-t", "--tag", required=True, help="tag for this build")
    sub.add_argument("-c", "--commit", default='',
                     help="build a particular sha1 commit; the commit is automatically appended to the tag")
    sub.add_argument("-r", "--rebuild", action="store_true",
                     help="re-pull latest hub source code from git and install any dependencies")
    sub.add_argument("-u", "--upgrade", action="store_true",
                     help="re-install the base Ubuntu packages")
    sub.add_argument("-l", "--local", action="store_true",
                     help="only build the image locally; don't push it to gcloud docker repo")
    sub.set_defaults(func=build_docker)

    sub = subparsers.add_parser('run', help='create/update {name} deployment on the currently selected kubernetes cluster'.format(name=NAME))
    sub.add_argument("-t", "--tag", default="", help="tag of the image to run")
    sub.add_argument("-r", "--replicas", default=None, help="number of replicas")
    sub.add_argument("-f", "--force",  action="store_true", help="force reload image in k8s")
    sub.add_argument("-g", "--gentle", default=30, type=int,
                     help="how gentle to be in doing the rolling update; in particular, will wait about this many seconds after each pod starts up (default: 30)")
    sub.add_argument("-d", "--database-nodes",  default='localhost', type=str, help="database to connect to.  If 'localhost' (the default), will run a local rethindkb proxy that is itself pointed at the rethinkdb-cluster service; if 'rethinkdb-proxy' will use that service.")
    sub.add_argument("-p", "--database-pool-size",  default=50, type=int, help="size of database connection pool")
    sub.add_argument("--database-concurrent-warn",  default=300, type=int, help="if this many concurrent queries for sustained time, kill container")
    sub.add_argument("--rethinkdb-proxy-tag", default="", help="tag of rethinkdb-proxy image to run")
    sub.add_argument("--test", action="store_true", help="using for testing so make very minimal resource requirements")
    sub.set_defaults(func=run_on_kubernetes)

    sub = subparsers.add_parser('delete', help='delete the deployment')
    sub.set_defaults(func=stop_on_kubernetes)

    sub = subparsers.add_parser('load-sendgrid', help='load the sendgrid password into k8s from disk',
                                formatter_class=argparse.ArgumentDefaultsHelpFormatter)
    sub.add_argument('path', type=str, help='path to directory that contains the password in a file named "sendgrid"')
    sub.set_defaults(func=lambda args: load_secret('sendgrid',args))

    sub = subparsers.add_parser('load-zendesk', help='load the zendesk password into k8s from disk',
                                formatter_class=argparse.ArgumentDefaultsHelpFormatter)
    sub.add_argument('path', type=str, help='path to directory that contains the password in a file named "zendesk"')
    sub.set_defaults(func=lambda args: load_secret('zendesk',args))

    util.add_deployment_parsers(NAME, subparsers, default_container='smc-hub')

    sub = subparsers.add_parser('status', help='display status info about concurrent and blocked, based on recent logs')
    sub.add_argument("-t", "--tail", default=100, type=int, help="how far back to go in log")
    sub.set_defaults(func=status)

    args = parser.parse_args()
    if hasattr(args, 'func'):
        args.func(args)
