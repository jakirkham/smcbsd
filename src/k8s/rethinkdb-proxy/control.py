#!/usr/bin/env python3
"""
Rethinkdb-proxy management/deployment script.
"""

import os, shutil, sys, tempfile
join = os.path.join

# Boilerplate to ensure we are in the directory of this path and make the util module available.
SCRIPT_PATH = os.path.split(os.path.realpath(__file__))[0]
sys.path.insert(0, os.path.abspath(os.path.join(SCRIPT_PATH, '..', 'util')))
os.chdir(SCRIPT_PATH)
import util

NAME='rethinkdb-proxy'

def build(tag, rebuild):
    v = ['sudo', 'docker', 'build', '-t', tag]
    if rebuild:  # will cause a git pull to happen
        v.append("--no-cache")
    v.append('.')
    util.run(v, path=join(SCRIPT_PATH, 'image'))

def build_docker(args):
    tag = util.get_tag(args, NAME)
    build(tag, args.rebuild)
    if not args.local:
        util.gcloud_docker_push(tag)

def run_on_kubernetes(args):
    args.local = False # so tag is for gcloud
    if args.replicas is None:
        args.replicas = util.get_desired_replicas(NAME, 2)
    tag = util.get_tag(args, NAME, build)
    print("tag='{tag}', replicas='{replicas}'".format(tag=tag, replicas=args.replicas))
    t = open(join('conf', '{name}.template.yaml'.format(name=NAME))).read()
    with tempfile.NamedTemporaryFile(suffix='.yaml', mode='w') as tmp:
        tmp.write(t.format(image=tag, replicas=args.replicas,
                               pull_policy=util.pull_policy(args)))
        tmp.flush()
        util.update_deployment(tmp.name)

    if NAME not in util.get_services():
        util.run(['kubectl', 'expose', 'deployment', NAME])

def stop_on_kubernetes(args):
    util.stop_deployment(NAME)

def expose(args):
    util.run(['kubectl', 'expose', 'deployment', NAME])

def forward_test(args):
    v = util.get_pods(run='rethinkdb-proxy')
    v = [x for x in v if x['STATUS'] == 'Running']
    if len(v) == 0:
        print("No rethinkdb-proxy nodes available")
    else:
        print("\n\nYou may connect to rethinkdb-proxy on localhost:\n\n")
        util.run(['kubectl', 'port-forward', v[0]['NAME'], '28015:28015'])

if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description='Control deployment of {name}'.format(name=NAME))
    subparsers = parser.add_subparsers(help='sub-command help')

    sub = subparsers.add_parser('build', help='build docker image')
    sub.add_argument("-t", "--tag", required=True, help="tag for this build")
    sub.add_argument("-r", "--rebuild", action="store_true", help="rebuild from scratch")
    sub.add_argument("-l", "--local", action="store_true",
                     help="only build the image locally; don't push it to gcloud docker repo")
    sub.set_defaults(func=build_docker)

    sub = subparsers.add_parser('run', help='create/update {name} deployment on the currently selected kubernetes cluster'.format(name=NAME))
    sub.add_argument("-t", "--tag", default="", help="tag of the image to run (default: most recent tag)")
    sub.add_argument("-f", "--force",  action="store_true", help="force reload image in k8s")
    sub.add_argument("-r", "--replicas", default=None, help="number of replicas")
    sub.set_defaults(func=run_on_kubernetes)

    sub = subparsers.add_parser('test', help='forward 28015 port from some pod to localhost for testing purposes')
    sub.set_defaults(func=forward_test)

    sub = subparsers.add_parser('delete', help='delete the deployment')
    sub.set_defaults(func=stop_on_kubernetes)

    util.add_deployment_parsers(NAME, subparsers)

    args = parser.parse_args()
    if hasattr(args, 'func'):
        args.func(args)
