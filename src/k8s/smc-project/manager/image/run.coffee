###
This is a service that watches:

 - projects in RethinkDB to see which are requested to be run,
 - the running projects in kubernetes to see which are actually running.

When there is a discrepancy it resolves it.

(c) 2016, William Stein, SageMathInc.

LICENSE: GPLv3

NOTE: This code doesn't depend on the rest of the SMC library.
###

IDLE_TIMEOUT_INTERVAL_M = 1  # check for need to idle timeout projects with this frequently

{DEFAULT_QUOTAS} = require('./upgrade-spec.coffee')

DEFAULTS =
    resources   :
        requests:
            memory : "#{DEFAULT_QUOTAS.req_memory}Mi"
            cpu    : "#{Math.ceil(DEFAULT_QUOTAS.req_cores*1000)}m"
        limits:
            memory : "#{DEFAULT_QUOTAS.memory}Mi"
            cpu    : "#{Math.ceil(DEFAULT_QUOTAS.cores*1000)}m"

    disk        : "#{DEFAULT_QUOTAS.disk_quota}m"

    preemptible : not DEFAULT_QUOTAS.member_host

child_process = require('child_process')
fs            = require('fs')
async         = require('async')
temp          = require('temp')    # https://www.npmjs.com/package/temp

rethinkdb = require('rethinkdb')

{retry_wrapper} = require('./util.coffee')

conn      = undefined  # connection to rethinkdb
DATABASE  = 'smc'

projects = {}

connect_to_rethinkdb = (cb) ->
    try
        authKey = fs.readFileSync("/secrets/rethinkdb/rethinkdb").toString().trim()
    catch
        authKey = undefined
    rethinkdb.connect {authKey:authKey, host:"rethinkdb-driver", timeout:15}, (err, _conn) ->
        conn = _conn
        cb?(err)

log = (m...) ->
    console.log("#{(new Date()).toISOString()}:",  m...)

# Create a changefeed of all potentially requested-to-be-running projects, which
# dynamically updates the projects object.
FIELDS = ['run', 'storage_server', 'disk_size', 'resources', 'preemptible', 'last_edited', 'idle_timeout', 'storage_ready']
init_projects_changefeed = (cb) ->
    query = rethinkdb.db(DATABASE).table('projects').getAll(true, index:'run')
    query = query.pluck(['project_id', 'kubernetes'].concat(FIELDS))
    query.changes(includeInitial:true, includeStates:true).run conn, (err, cursor) ->
        if err
            log('error setting up rethinkdb query', err)
            cb?(err)
            return
        state = 'initializing'
        cursor.each (err, x) ->
            if err
                throw "error in changefeed -- #{err}"
            if x.state
                state = x.state
                if state == 'ready'
                    # done loading initial state of all projects.
                    cb?()
                    return
            if x.new_val
                project_id = x.new_val.project_id
                z = projects[project_id] ?= {}
                changed = {}
                for field in FIELDS
                    if JSON.stringify(z[field]) != JSON.stringify(x.new_val[field])   # use due to resources being object
                        z[field] = x.new_val[field]
                        changed[field] = true
                if state == 'ready' and z.run and not changed.run and (changed.resources or changed.preemptible or changed.disk_size or changed.storage_ready)
                    log("deployment change for '#{project_id}' ", changed)
                    # Currently running with no change to run state.
                    # Something changed which can be done via editing the deployment using kubectl
                    kubectl_update_project(project_id)
                    return
            else if x.old_val  # no new value -- removed from changefeed result, so now false.
                project_id = x.old_val.project_id
                z = projects[project_id] ?= {}
                z.run = false
            if state == 'ready' and project_id?
                reconcile(project_id)
            return   # explicit return (undefined) -- otherwise last value gets returned, which stops iteration!

# Periodically check for idle running projects, and if so switch
# them from the run=true to run=false.
idle_timeout_check = () ->
    log('idle_timeout_check')
    now = new Date()
    for project_id, project of projects
        if project.run and project.idle_timeout and now - project.last_edited >= project.idle_timeout * 1000*60
            rethinkdb.db(DATABASE).table('projects').get(project_id).update(run:false).run conn, (err) ->
                if err
                    log "idle_timeout_check '#{project_id}' -- ERROR", err
                else
                    log "idle_timeout_check '#{project_id}' -- set run=false"

start_idle_timeout_monitor = (cb) ->
    setInterval(idle_timeout_check, IDLE_TIMEOUT_INTERVAL_M*60*1000)
    cb()

project_id_from_labels = (lbl) ->
    for x in lbl.split(',')
        w = x.split('=')
        if w[0] == 'project_id'
            return w[1]

# Maintain current status of all project deployments
init_kubectl_deployment_watch = (cb) ->
    # The Headers include: NAME   DESIRED   CURRENT   UP-TO-DATE   AVAILABLE   AGE  LABELS
    # kubectl get deployments --show-labels --selector=run=smc-project --watch

    headers = undefined
    process = (line) ->
        v = split(line)
        if not v or v.length == 0
            return
        if line.indexOf('smc-project') == -1
            # Headers
            headers = v
        else
            # New info
            project_id = project_id_from_labels(v[v.length-1])
            x = projects[project_id] ?= {}
            k = x.kubernetes_deployment_watch ?= {}
            for i in [0...v.length]
                k[headers[i]] = v[i]
            write_kubernetes_data_to_rethinkdb(project_id)
            reconcile(project_id)

    # Initialize
    run "kubectl get deployments --show-labels --selector=run=smc-project", (err, output) ->
        if err
            cb?(err)
            return
        for line in output.split('\n')
            process(line)

        cb?()

        # Now watch (NOTE: don't do --no-headers here, in case there wasn't nothing output above)
        r = child_process.spawn('kubectl', split('get deployments --show-labels --selector=run=smc-project --watch-only'))

        stdout = ''
        r.stdout.on 'data', (data) ->
            stdout += data.toString()
            while true
                i = stdout.indexOf('\n')
                if i == -1
                    break
                line = stdout.slice(0,i)
                stdout = stdout.slice(i+1)
                process(line)

        r.on 'exit', (code) ->
            log("kubectl terminated normally", code)
            init_kubectl_deployment_watch()

        r.on 'error', (err) ->
            log("kubectl subprocess error", err)
            init_kubectl_deployment_watch()

write_kubernetes_data_to_rethinkdb = (project_id, cb) ->
    cur = projects[project_id].kubernetes
    kubernetes_watch = projects[project_id].kubernetes_deployment_watch
    desired   = parseInt(kubernetes_watch.DESIRED)
    available = parseInt(kubernetes_watch.AVAILABLE)
    if cur?.desired == desired and cur?.available == available
        cb?()
        return
    query = rethinkdb.db(DATABASE).table('projects').get(project_id)
    log 'write_kubernetes_data_to_rethinkdb ', {desired:desired, available:available}
    query = query.update(kubernetes:{desired:desired, available:available})
    query.run(conn, (err)->cb?(err))

# get changed to true when we first run reconcile_all
_reconcile_ready = false
reconcile = retry_wrapper (project_id, cb) ->
    if not _reconcile_ready
        cb()
        return
    x = projects[project_id]
    desired = x.kubernetes_deployment_watch?.DESIRED
    dbg = (m...) -> log("reconcile('#{project_id}')", m...)
    dbg()
    if x.run
        if not x.storage_server?
            # This will assign a storage server, which will eventually cause storage_ready to
            # be true, allowing things to run.
            dbg("assign storage server")
            get_storage_server(project_id, cb)
        else if x.storage_ready and desired != '1'
            dbg("starting because x = ", x)
            kubectl_update_project(project_id, cb)
        else
            cb()
    else
        if desired == '1'
            dbg("stopping because x = ", x)
            kubectl_stop_project(project_id, cb)
        else
            cb()

reconcile_all = (cb) ->
    _reconcile_ready = true
    for project_id, _ of projects
        reconcile(project_id)
    cb?()

replace_all = (string, search, replace) ->
    string.split(search).join(replace)

# Used for starting projects:
deployment_template = undefined
deployment_yaml = (project_id, storage_server, disk_size, resources, preemptible) ->
    deployment_template ?= fs.readFileSync('smc-project.template.yaml').toString()
    params =
        project_id     : project_id
        image          : process.env['DEFAULT_IMAGE']          # explicitly set in the deployment yaml file
        namespace      : process.env['KUBERNETES_NAMESPACE']   # explicitly set in the deployment yaml file
        storage_server : storage_server
        disk_size      : disk_size
        preemptible    : if preemptible  then 'true' else 'false'
        resources      : JSON.stringify(resources).replace(/"/g, '').replace(/:/g,': ')  # inline-map yaml
        pull_policy    : 'IfNotPresent'
    s = deployment_template
    for k, v of params
        s = replace_all(s, "{#{k}}", "#{v}")
    #log('s = ', s)
    return s

# split on whitespace
split = (s) -> s.match(/\S+/g)

run = (s, cb) ->
    log("running '#{s}'")
    child_process.exec s, (err, stdout, stderr) ->
        #log("output of '#{s}' -- ", stdout, stderr)
        cb?(err, stdout + stderr)

write_deployment_yaml_file = (project_id, cb) ->
    info = storage_server = disk_size = resources = preemptible = undefined
    async.series([
        (cb) ->
            temp.open {suffix:'.yaml'}, (err, _info) ->
                info = _info
                cb(err)
        (cb) ->
            async.parallel([
                (cb) ->
                    get_storage_server project_id, (err, r) ->
                        storage_server = r
                        cb(err)
                (cb) ->
                    get_disk_size project_id, (err, r) ->
                        disk_size = r
                        cb(err)
                (cb) ->
                    get_resources project_id, (err, r) ->
                        resources = r
                        cb(err)
                (cb) ->
                    get_preemptible project_id, (err, r) ->
                        preemptible = r
                        cb(err)
            ], cb)
        (cb) ->
            fs.write(info.fd, deployment_yaml(project_id, storage_server, disk_size, resources, preemptible))
            fs.close(info.fd, cb)
    ], (err) ->
        cb(err, info.path)
    )

# Start a project running
kubectl_update_project = (project_id, cb) ->
    log 'kubectl_update_project ', project_id
    if projects[project_id].starting?
        projects[project_id].starting.push(cb)
        return
    projects[project_id].starting = [cb]
    path = action = undefined
    async.series([
        (cb) ->
            write_deployment_yaml_file project_id, (err, _path) ->
                path = _path
                cb(err)
        (cb) ->
            s = "kubectl get deployments --no-headers --selector=run=smc-project,project_id=#{project_id} | wc -l"
            run s, (err, num) ->
                if err
                    cb(err)
                else
                    if num.trim() == '0'
                        action = 'create'
                    else
                        action = 'replace'
                    cb()
        (cb) ->
            run("kubectl #{action} -f #{path}", cb)
        (cb) ->
            rethinkdb.db(DATABASE).table('projects').get(project_id).update(last_edited:new Date()).run(conn, cb)
    ], (err) ->
        if err
            log "failed to update '#{project_id}': ", err
        else
            log "updated '#{project_id}'"
        if path?
            try
                fs.unlink(path)
            catch
                # ignore
        w = projects[project_id].starting
        delete projects[project_id].starting
        for cb in w
            cb?(err)
    )

get_storage_server = (project_id, cb) ->
    storage_server = projects[project_id]?.storage_server
    if storage_server?
        cb(undefined, storage_server)
        return
    async.series([
        (cb) ->
            # assign project to a storage server
            get_all_storage_servers (err, x) ->
                if err
                    cb(err)
                else if x.length == 0
                    cb("no storage servers")
                else
                    storage_server = random_choice(x)
                    cb()
        (cb) ->
            # save assignment to database, so will reuse it next time.
            query = rethinkdb.db(DATABASE).table('projects').get(project_id).update(storage_server:storage_server).run(conn, cb)
    ], (err) ->
        cb?(err, storage_server)
    )

random_choice = (array) ->
    array[Math.floor(Math.random() * array.length)]

# Determine a valid storage server -- this code is ugly because it can get called many times in
# parallel, we want to cache the result, but only for a few seconds.
storage_servers = undefined
storage_servers_cbs = undefined
get_all_storage_servers = (cb) ->
    if storage_servers?
        log 'using already defined storage_server ', storage_servers
        cb(undefined, storage_servers)
    else
        if storage_servers_cbs?
            storage_servers_cbs.push(cb)
            return
        storage_servers_cbs = [cb]
        run 'kubectl get pods --selector="storage=projects" --show-labels --no-headers', (err, output) ->
            if err
                w = storage_servers_cbs
                storage_servers_cbs = undefined
                for cb in w
                    cb(err)
            else
                storage_servers = []
                for line in output.split('\n')
                    v = line.match(/\S+/g)
                    if v
                        storage_servers.push(parseInt(v[v.length-1].split(',')[0].split('=')[1]))
                setTimeout((()->storage_servers = undefined), 10000)  # cache for 10s
                log 'got new storage servers list ', storage_servers
                w = storage_servers_cbs
                storage_servers_cbs = undefined
                for cb in w
                    cb(undefined, storage_servers)

get_disk_size = (project_id, cb) ->
    cb(undefined, projects[project_id]?.disk_size ? DEFAULTS.disk)

get_resources = (project_id, cb) ->
    # TODO -- note that 200Mi really is pretty much the minimum needed to run the local hub at all!
    resources = projects[project_id]?.resources ? DEFAULTS.resources
    resources.requests        ?= {}
    resources.requests.memory ?= DEFAULTS.resources.requests.memory
    resources.requests.cpu    ?= DEFAULTS.resources.requests.cpu
    resources.limits          ?= {}
    resources.limits.memory   ?= DEFAULTS.resources.limits.memory
    resources.limits.cpu      ?= DEFAULTS.resources.limits.cpu

    cb(undefined, resources)

get_preemptible = (project_id, cb) ->
    cb(undefined, projects[project_id]?.preemptible ? DEFAULTS.preemptible)

# Stop a project from running
kubectl_stop_project = (project_id, cb) ->
    log 'kubectl_stop_project ', project_id
    if projects[project_id].stopping?
        projects[project_id].stopping.push(cb)
        return
    projects[project_id].stopping = [cb]
    run "kubectl delete deployments smc-project-#{project_id}", (err) ->
        if err
            log "failed to stop '#{project_id}': ", err
        else
            log "stopped '#{project_id}'"
        w = projects[project_id].stopping
        delete projects[project_id].stopping
        for cb in w
            cb?(err)

# Watch output of "kubectl pod" for all projects; this gives us the ip addresses, and other pod-specific info
## TODO: DEAL with multiple pods for same deployment!!!
init_kubectl_pod_watch = (cb) ->
    headers = undefined
    pod_names = {}
    process = (line) ->
        v = split(line)
        if not v or v.length == 0
            return
        if line.indexOf('smc-project') == -1   # Headers
            headers = v
        else
            # New info

            # When changing things about a project, the pod output gives info both
            # about the newly creating pod and the old pod being destroyed, in potentially
            # random order.  So we only record info about the most recent one when
            # watching.  This is also why we sort by creationTimestamp (for the initial load).
            name = v[0]
            if not pod_names[project_id]?
                # initialize
                pod_names[project_id] = [name]
            else
                # already seen a pod with this project_id
                z = pod_names[project_id]
                if name in z
                    if z[z.length-1] != name
                        # already known but not most recent pod -- ignore
                        return
                else
                    # not known -- becomes new one we watch
                    z.push(name)

            # extract project_id from final labels column (properly and safely)
            project_id = project_id_from_labels(v[v.length-1])

            # update changed fields of projects[project_id].kubernetes in the database (and the projects object)
            x = projects[project_id] ?= {}
            x.kubernetes ?= {}
            k = {}
            for i in [0...v.length]
                k[headers[i]] = if v[i] == '<none>' then '' else v[i]
            update = undefined
            for field in ['READY', 'STATUS', 'RESTARTS', 'IP', 'NODE']
                field0 = field.toLowerCase()
                if x.kubernetes[field0] != k[field]
                    update ?= {}
                    update[field0] = k[field]
            if update?
                update_kubernetes_db_info(project_id, update)

    # Initialize
    args = 'get pods --sort-by=metadata.creationTimestamp -o wide --show-labels --selector=run=smc-project'
    run "kubectl #{args}", (err, output) ->
        if err
            cb?(err)
            return
        for line in output.split('\n')
            process(line)

        cb?()

        # Watch
        r = child_process.spawn('kubectl', split("#{args} --watch-only"))
        stdout = ''
        r.stdout.on 'data', (data) ->
            stdout += data.toString()
            while true
                i = stdout.indexOf('\n')
                if i == -1
                    break
                process(stdout.slice(0,i))
                stdout = stdout.slice(i+1)
        r.on 'exit', (code) ->
            log("kubectl watch pods terminated normally", code)
            init_kubectl_pod_watch()
        r.on 'error', (err) ->
            log("kubectl watch pods subprocess error", err)
            init_kubectl_pod_watch()

update_kubernetes_db_info = (project_id, update, cb) ->
    # TODO error handling
    rethinkdb.db(DATABASE).table('projects').get(project_id).update(kubernetes:update).run(conn, (err) -> cb?(err))

main = () ->
    async.series [connect_to_rethinkdb,
                  init_projects_changefeed,
                  init_kubectl_deployment_watch,
                  init_kubectl_pod_watch,
                  reconcile_all,
                  start_idle_timeout_monitor], (err) ->
        if err
            log("FAILED TO INITIALIZE! ", err)
            process.exit(1)
        else
            log("SUCCESSFULLY INITIALIZED; now RUNNING")

main()
