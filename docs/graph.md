# Graph

The Graph section of a Go service shows how the services of its namespace talk to each other: one box per service, per postgres Cluster and per bucket, an arrow per call that their sources declare, each arrow coloured by its number of calls in a time window, and the requests of that window, each with the boxes and arrows it went through, its timeline and its log lines, found by its correlation id. The boxes and arrows come from the Deployments of the namespace of the project's [current working environment](projects.md#current-working-environment) and from the sources of their images on GitHub; the calls and the requests come from the traces of the environment's Jaeger. The engine of the main device reads them, so the section also works in the windows of remote devices. The project enables the section in Project Settings, and its Dashboard can show four widgets of it ([Dashboard › Graph widgets](dashboard.md#graph-widgets)). This document specifies the section, where its boxes, arrows, calls and requests come from, its layout, its navigation, the view of a request and the reading of Jaeger.

## Section

| Property    | Value                                                                                                                                         |
| ----------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| Section     | `graph` ([ProjectSection](engine-api.md#projectsection))                                                                                      |
| Title       | `Graph`                                                                                                                                       |
| SF Symbol   | `circle.hexagongrid`                                                                                                                          |
| Shortcut    | none; View ▸ Graph ([Menus and keyboard shortcuts](ui.md#menus-and-keyboard-shortcuts))                                                       |
| Sidebar row | in the Go Service category, after API Explorer, without badge, while the active project's graph is enabled ([Sidebar](ui.md#sidebar))         |
| Shows       | the boxes and arrows of the namespace of the current working environment, their calls and the requests of a time window ([Sources](#sources)) |

The title, the symbol, the place of the row, its condition and the absence of a shortcut come from the user. View ▸ Graph is a design-time choice. Default chosen at design time.

### Enabling

- A project's graph is enabled while its type is `goService` and the checkbox `Enable graph` of the Graph field of its Project Settings is checked, the key `graphEnabled` of its `project.yml`, absent meaning off ([Project settings](projects.md#project-settings), [Project file](data-model.md#project-file)). A sub project whose `Use parent settings` is on uses its parent's graph, as the parent resolves it, whatever its own key says ([Sub projects](projects.md#sub-projects)). The [ProjectDetail](engine-api.md#projectdetail) gives the result as `graphEnabled`.
- The row shows while the active project's ProjectDetail in the window's workspace has `graphEnabled`. It follows `project.updated`, on This Mac and in remote windows: checking the box, in the project or in its parent, shows the row at once; unchecking it, changing the type or turning `Use parent settings` on or off hides or shows it at once.
- View ▸ Graph, without shortcut, is enabled while the row shows.
- When the window's section is `graph` and the active project's loaded detail has no enabled graph, after a switch of project or device, a navigation, or a change of the setting, the window selects Dashboard.
- Claude reads `graphEnabled` with `get_project` and has no tool to change it ([get_project](mcp.md#get_project)).

The checkbox, its default, its key, the parent's value for a sub project and Claude reading it without changing it come from the user. The leave to Dashboard is a design-time choice, as for [Builds](builds.md#visibility). Default chosen at design time.

## Layout

```
┌────────────────────────────────────────────────────────────────────────────────┐
│ production · yc-production          4 requests in the window, 6 traces read …  │ pane header
├────────────────────────────────────────────────────────────────────────────────┤
│ Window [Last 5 minutes ⌄]  [Correlation ID            ] Find   [Service      ] │ controls
├────────────────────────────────────────────────────────────────────────────────┤
│                                                 Right-click: back  Show All   │
│                       the graph                 [−] [+] Fit 100%               │
├─────────────────────────────────────────────┬──────────────────────────────────┤
│ the requests of the window                  │ the request chosen: Timeline, Log│
└─────────────────────────────────────────────┴──────────────────────────────────┘
```

- The pane header, 36 points high ([Pane headers](ui.md#pane-headers)), shows the name of the current working environment, then ` · ` and its namespace when it has one, in the headline font, and at its trailing edge the [status line](#status-line) in the caption font.
- The controls bar under it holds the `Window` pop-up of the [time window](#time-window), the [Correlation ID](#correlation-id-field) field in SF Mono with its `Find` button, and the [Service](#service-field) field; the message of a field shows in red after it.
- The graph fills the rest of the height above the bottom pane, which holds the [requests](#requests) on the left and the [request chosen](#request-view) on the right. The divider between the graph and the bottom pane, and the one between its two halves, can be dragged. The zoom controls float at the top right of the graph ([Zoom and pan](#zoom-and-pan)).
- Without environment, which a Go service may have, the section shows `Add an environment in Project Settings.` with a `Project Settings…` button, which selects the window's Project Settings section, as the [Instances widget](dashboard.md#instances-widget) does; it calls no method.
- While the first read of the graph runs, the graph area shows a small spinner with `Reading the graph…`. A first read that fails shows the engine's message in red in place of the graph.

The window pop-up, the controls bar under the pane header, the environment's name before the namespace, the messages without environment and of the first read are design-time choices. Default chosen at design time.

## Sources

Every read of the graph is a call of [graph.read](engine-api.md#graphread) with the project's current working environment and the [time window](#time-window). The engine of the main device runs kubectl with the environment's kubeconfig file, in its namespace, as the Instances widget does ([Rules of the Kubernetes tools](mcp.md#rules-of-the-kubernetes-tools), rules 6 to 9), reads the sources of the services on GitHub with the GitHub CLI, and reads Jaeger through a port forward ([Jaeger](#jaeger)).

### Boxes

- **Services.** `kubectl … get deployments -o json` lists the Deployments of the namespace. A Deployment is a service box when the image of a container of its pod template, the first one that has this form, is `ghcr.io/<owner>/<repository>:sha-<commit>`: `<owner>` and `<repository>` of the letters, digits, `.`, `-` and `_` of a GitHub page ([GitHub page](projects.md#github-page)), `<commit>` of 7 to 40 hexadecimal digits. The box is named after the Deployment; its repository is `github.com/<owner>/<repository>` and its commit `<commit>`, the deployed one. A Deployment with any other image has no box, nor one whose repository is named `yc-shared`, the library of the services.
- **Sources.** The sources of a service are the files `go.mod` and `deployment/values-prod.yml` of its repository at its commit, each read with `gh api --header=Accept: application/vnd.github.raw repos/<owner>/<repository>/contents/<path>?ref=<commit>`. A file that the commit does not have, which gh answers with HTTP 404, is read as an empty file. The engine keeps every file read, by repository, commit and path, until it stops; a failed read is not kept and is made again at the next read of the graph.
- **postgres Cluster.** A service has a Cluster box, named after it, when `postgres.enabled` of its values file is `true`, `yes` or `on`, in any letter case, or when its `go.mod` requires a module whose path ends with `/yc-shared/gormpg`, or a major version of it (`/yc-shared/gormpg/v2`).
- **Bucket.** A service has a bucket box, named after it, when `s3.enabled` of its values file is true in the same way, or when its `go.mod` requires a module whose path ends with `/yc-shared/s3store`, or a major version of it.
- The values file is read as nested maps of scalars, each by its dotted path (`postgres.enabled`), its comments dropped, its quoted values unquoted, its lists and flow values kept as text; `go.mod` gives the module paths of its `require` lines and blocks, never those of its `replace` directives.

### Arrows

The arrows come from the sources only; the traces only colour them ([Calls and colours](#calls-and-colours)).

- A service has an arrow to its Cluster and one to its bucket.
- A service has an arrow to another service of the namespace when its `go.mod` requires the module of that service's repository, `github.com/<owner>/<repository>`, or a module below it, for example its `client` module `github.com/<owner>/<repository>/client`. A service never has an arrow to itself.
- The boxes are listed services first, by name, then the Cluster and the bucket of each service, in the order of the services; the arrows by their service, in the order of the services: its calls to the other services, by name, then the arrow to its Cluster and the one to its bucket.

### Failures of the sources

- A kubectl failure, for example a cluster that cannot be reached, fails the read with the engine's message ([graph.read](engine-api.md#graphread)); the graph of the last read that succeeded stays, and the message shows in red in the [status line](#status-line).
- A source that cannot be read for another reason than its absence, for example gh missing, gh not logged in or a network failure, leaves its service box without the arrows its sources give, and the read gives `The sources of <deployment> cannot be read: <reason>.`, `<reason>` being `gh was not found in the PATH of the login shell` without gh, `gh is not logged in; run gh auth login in Terminal` when gh needs a login, `timeout` after 30 seconds, or else the first line of gh's standard error, as [Builds › Failures](builds.md#failures) reads it; the status line shows it after the read's text.

The images of `ghcr.io` with their `sha-<commit>` tags, `go.mod` and `deployment/values-prod.yml` at the deployed commit, the Cluster from `postgres.enabled` or gormpg, the bucket from `s3.enabled` or s3store, the calls from the modules of the other services and yc-shared never being a box come from the user. Reading the files with the GitHub CLI, a missing file read as empty, the cache, the calls found from the repository of the other service's image, the forms of the owner, the repository and the commit, the first container with that form and the failures are design-time choices. Default chosen at design time.

## Layout of the graph

The layout follows the service map of AWS X-Ray, as the user drew it in a proof of concept:

- Every box is a round node with the icon of its kind, its name under it: `shippingbox` for a service, `cylinder.split.1x2` for a Cluster, `archivebox` for a bucket, `person.2` for the [Client](#request-view). A Cluster or a bucket has its kind written under its name: `postgres Cluster`, `bucket`.
- The services are spread over the whole plane by a force-directed layout: the services push each other away, a call pulls its two services together, and a weak pull to the centre keeps the parts that call nothing in sight. There are no columns: a service is placed by its calls, not by its depth in the calls.
- The Cluster and the bucket of a service, and any box that is not a service and that a service calls, sit on a ring around it, 95 points from its centre, more when it has more than 5, so that two of them stay 110 points apart. Each goes in the widest gap left by the arrows to the other services and by the boxes already on the ring, looked for every 5 degrees from straight up, above or beside its service, never below it, where the name of the service hangs, unless the ring has no room left there; a ring too crowded to place its boxes one by one is spread evenly around its service. The name and the kind of a box of a ring are written on its outer side, away from its service: above it, on its left, on its right or below it; its number of calls is written after its kind (`postgres Cluster · 29 calls`, `bucket · 1 call`), in the colour of its arrow, in place of on its short arrow.
- A service keeps the room of its ring free: no two nodes are closer than 130 points, a node of a ring and its service excepted. A box no service calls is placed like a service.
- The layout is computed once for the graph, from the same starting place each time, so a node stays where it is between two reads and between two openings of the section.
- The arrows are thin curves from the edge of a node to the edge of the other, bent to their left, so that a call each way is drawn as two curves apart, with an arrowhead at their end. The number of calls of an arrow is written at its middle in a capsule of its colour when the zoom is 50% or more, and always in the view of a request and of a service in focus.

The layout, its numbers and the arrows come from the user. The icons are design-time choices. Default chosen at design time.

## Navigation

### Zoom and pan

- Pinching zooms around the pointer, from 10% to 300%; dragging the background pans; the buttons `−` (`minus.magnifyingglass`, tooltip `Zoom out`) and `+` (`plus.magnifyingglass`, tooltip `Zoom in`) zoom out and in by 25% around the centre of the graph, and `Fit` shows every node shown with its name, at 150% at most. The zoom is written after `Fit`, for example `100%`.
- The graph opens fitted to the view, and each change of the view (a focus, a request, back, Show All) fits it again. Until the zoom or the place is changed by hand, the graph fits again when the size of the view changes.
- The names are never written smaller than 9 points, and are hidden below 30%, where the nodes are too close for them: hovering a node shows its name, with its kind for a node that is not a service.

### Focus on a service

- A click on a service keeps only it, the boxes it calls and the services that call it, with the arrows to and from it, laid out on their own by the same layout and fitted to the view; the others are hidden. The node of the service in focus has a thicker border in the accent colour. A click on another service of the focus moves the focus to it. A click on a box that is not a service, and a click on the background, do nothing.
- A right-click anywhere on the graph goes back to the view before: from a request to the focus it was chosen in, from a focus to the focus before it, and to the whole graph at last. While a view other than the whole graph shows, `Right-click: back` and the button `Show All`, which goes back to the whole graph at once, show at the left of the zoom controls.

### Service field

- The `Service` field suggests, while text is typed, the services whose name holds the text, any part of it, in upper or lower case, the 10 first by name. Choosing one, or typing a whole name, focuses on it; Return focuses on the service whose whole name is typed, or on the only service that matches.
- Return on a text that matches no service shows `no service found for this name` in red after the field, until the text changes.

The navigation, its numbers, the right-click, Show All, the field and its message come from the user. Default chosen at design time.

## Calls and colours

### Time window

- The `Window` pop-up chooses the time window of the section: `Last 5 minutes`, the default, `Last hour`, `Last 24 hours` and `Last 7 days`. Each window of the app keeps its own choice per project while the app runs.
- The section reads the graph when it appears, then 5 seconds after the end of each read, while it shows; and at once when the window changes, when the current working environment changes and when one of its fields changes.
- A window ends at the time of the read: `Last hour` is the hour before the read.

### Calls of an arrow

- A span of Jaeger is a call of an arrow when it is a client span of a service of the graph, the `service.name` of its process: a span whose `db.system.name` is `postgresql` is a call of the arrow to that service's Cluster; a span whose `rpc.system` is `aws-api` and `rpc.service` `S3`, of the arrow to its bucket; any other client span with a `server.address`, of the arrow to the service named by the first label of that address. A span that matches no arrow of the graph is not counted.
- An arrow's calls are those of the spans of the window's traces that started in the window. The calls of the startup of a service, its migration and the check of its bucket, count like any other call.

### Colour of an arrow

The busiest arrow shown is red; the others lie between green and red in proportion of their number of calls to the busiest one: the hue goes from 120° at 0 calls to 0° at the busiest count, at saturation 90% and brightness 85%. An arrow without any call in the window is grey. In the view of a request, the numbers are those of the request alone and the busiest arrow is that of the request.

The windows, the read every 5 seconds, the calls of each arrow and the colours come from the user. The windows kept per window of the app and the reads after a change are design-time choices. Default chosen at design time.

## Requests

The bottom left pane lists every request of the window, newest first, in a table:

| Column                  | Value                                                                                        |
| ----------------------- | -------------------------------------------------------------------------------------------- |
| Correlation ID          | The request's correlation id, in SF Mono.                                                    |
| Start                   | Its start time, `HH:mm:ss.SSS`.                                                              |
| First service and route | Its first service, a space, its route: `<method> <route>`, for example `yc-front GET /page`. |
| Status                  | Its answer status, in red from 400; `–` without one.                                         |
| Duration                | Its duration in milliseconds, with one decimal: `12.4 ms`.                                   |
| Items hit               | The number of boxes its spans touched.                                                       |

- A request is a trace whose first span, the span whose parent is not in the trace, the earliest when several, is a server span of a service; the traces of the startup of a service have none. Its route is `http.request.method` and `http.route` of that span, or its name without `http.route`; its status is its `http.status_code`.
- The correlation id of a request is its trace id, 32 lowercase hexadecimal digits, as Jaeger shows it, everywhere in the app.
- A request is listed once it is 3 seconds old, at the next read: before, the spans of a service can be missing, since each service sends them at most a second after they end, and the request would look as if it started in the next service.
- The boxes a request touched are the services of its spans and the targets of the arrows of its calls.

### Correlation ID field

- The `Correlation ID` field filters the list as it is typed: only the requests whose correlation id holds the text typed stay, in their order, the text matching any part of the id, in upper or lower case. An empty field lists every request again.
- The field suggests the ids of those requests, the 10 newest, each with its first service and route under it; choosing one, or typing a whole id of the list, chooses that request.
- Return or `Find` chooses the request of the id typed: one of the list, or else the request Jaeger has with that id, whenever it started within the days Jaeger keeps ([graph.request](engine-api.md#graphrequest)). An id that matches nothing shows `no request found for this correlation id` in red after `Find`, until the text changes.

The list, its columns, the settling of 3 seconds, the field and its message come from the user. The formats of the columns are design-time choices. Default chosen at design time.

## Request view

A click on a row, or a request chosen with the Correlation ID field, opens the view of the request:

- The graph shows only the boxes and the arrows the request hit, the others hidden, laid out on their own by the same layout and fitted to the view, with a Client node, the client that sent the request, whose arrow goes into the first service: the entry point. The route of the request is written under the Client node, in the colour of its arrow, the arrow being too short for it.
- Each arrow has the number of its calls in the request alone, the Client's arrow 1, coloured relative to the busiest arrow of the request.
- A request opened while a service is in focus is opened over that focus; a right-click goes back to it. A request opened while another request is open replaces it.
- The row of the request shown is selected in the list. While the request stays in the window, each read replaces it with its newest summary, and its detail is read again: its last spans can arrive after it was opened.

The bottom right pane shows the request chosen: its correlation id in SF Mono, under it `<first service> <route> · <status> · <duration> · <n> items hit · <start date and time>`, then a segmented control with `Timeline` and `Log (<n>)`, `<n>` being its number of log lines. Without a request chosen, it shows `Choose a request, or type its correlation id`. The engine reads the timeline and the log lines with [graph.request](engine-api.md#graphrequest); a failed read shows the engine's message in red in place of them.

### Timeline

- Each span of the request, one under the other, in the order it started, indented by 10 points per span it is below the first one: the icon of its kind, its name, its service under the name, its start from the start of the request (`+3.2 ms`), its duration, and a bar placed on the duration of the request. A span that failed, its status `ERROR` or its `error` attribute `true`, has a red bar.
- The kinds and their icons: HTTP request `arrow.down.circle`, HTTP call `arrow.up.right.circle`, SQL `cylinder.split.1x2`, redis `bolt.horizontal`, S3 `archivebox`, Kafka message published `envelope.arrow.triangle.branch`, Kafka message consumed `envelope.open`, any other span `circle.dotted`; the icon's tooltip is the kind's name.
- A click on an HTTP request or call selects it and shows its details under the timeline: its kind, its service, then `Method`, `URL` with its query, `Status`, in red from 400, `Request headers` and `Response headers`, each header as its name and its values, or `none`. A header whose value is `[hidden]` shows it in the secondary colour. A click on the selected span hides its details; a click on another kind of span does nothing.

### Log tab

The Log tab lists the log lines of every service for the request, by time: each line's time, `HH:mm:ss.SSS`, with its start from the request under it, its service, its level, in red for `error`, `fatal` and `panic`, orange for `warning` and `warn`, secondary for `debug` and `trace`, its message, and its fields as `<name>=<value>` in SF Mono. Without log lines it shows `No log line for this request`.

The request view, the Client node, the counts of the request, the timeline, its kinds and icons, the HTTP details and the Log tab come from the user. Default chosen at design time.

## Jaeger

### Jaeger of an environment

- Each environment names the Kubernetes Service of its Jaeger in the Jaeger field of the [Environments section](projects.md#environments), `<namespace>/<name>`, for example `jaeger/jaeger`, the key `jaeger` of the environment ([Project environment](data-model.md#project-environment)). A sub project changes it for an inherited environment as it changes the other fields ([Inherited environments](projects.md#inherited-environments)).
- The engine reaches Jaeger's query API on port 16686 of that Service through `kubectl --kubeconfig=<file> --namespace=<namespace> port-forward service/<name> --address=127.0.0.1 :16686`, run as the kubectl commands of the [Kubernetes tools](mcp.md#rules-of-the-kubernetes-tools) are, in the project root, the namespace being the Service's; it waits at most 30 seconds for the line `Forwarding from 127.0.0.1:<port> -> 16686`.
- The engine keeps one port forward per kubeconfig file and Service, used by every read of every project and window, and stops it 60 seconds after the last read that used it, when the engine stops, or when kubectl exits by itself; the next read starts a new one.

### Reading the traces

- Jaeger is read through its v3 API, in OTLP json: `GET /api/v3/traces?query.service_name=<service>&query.start_time_min=<start>&query.start_time_max=<end>&query.search_depth=10000`, the times in RFC 3339 with their fraction of second, in UTC. The engine searches each service of the graph and merges the traces by id. A search that returns 10,000 traces, the most Jaeger returns, is made again on each half of its window, until none is full, so that every trace of the window is read. Jaeger's answer `404` for a service that has sent no span yet gives no trace.
- The trace of a correlation id is read with `GET /api/v3/traces/<id>`. An id that Jaeger refuses or does not have gives no request.
- The service of a span is the `service.name` of its resource. The attributes the app reads, the contract between the services and the app:

| Span                      | Kind               | Name, for example           | Attributes read                                                                                                                                                  |
| ------------------------- | ------------------ | --------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| a request                 | server             | `GET /page`                 | `http.route`, `http.request.method`, `http.status_code`, `url.path`, `url.query`, `http.request.header.<name>`, `http.response.header.<name>`                    |
| a call to another service | client             | `GET /greeting`             | `server.address`, the host of the URL, whose first label is the service; `http.request.method`, `url.full`, `http.status_code`, the request and response headers |
| a postgres query          | client             | `INSERT yc_poc_back_values` | `db.system.name` `postgresql`; another `db.system.name` makes an SQL span, and `redis` a redis span                                                              |
| an S3 operation           | client             | `S3 PutObject`              | `rpc.system` `aws-api`, `rpc.service` `S3`                                                                                                                       |
| a Kafka message           | producer, consumer | `orders publish`            | the kind only                                                                                                                                                    |

- `http.response.status_code` is read too, before `http.status_code`, the name Jaeger gives it. A header attribute whose value is an array has its values joined with `, `.
- An event of a span with the attribute `log.level` is a log line of the request: its name is the message, its time the line's time, `log.level` its level and its other attributes its fields.
- A span whose status code is `ERROR` has failed.

### Without Jaeger

When the environment has no Jaeger, or Jaeger cannot be reached, the boxes and arrows show, every arrow grey, the request list is empty, and the status line shows `Jaeger cannot be reached: <reason>`, `<reason>` being `Environment “<name>” has no Jaeger.`, the failure of the port forward as kubectl's failures are written ([Rules of the Kubernetes tools](mcp.md#rules-of-the-kubernetes-tools), rule 9), or the failure of the HTTP request or the error Jaeger answers. The next read tries again.

The Jaeger field, its form, the port forward with the environment's kubeconfig file, the v3 API and the message come from the user. One forward per file and Service, its 60 seconds, the 30 seconds of its start and the reasons are design-time choices. Default chosen at design time.

## Status line

The status line, at the trailing edge of the pane header, shows:

- `Reading the graph…` until the first read ends;
- after a read: `<n> requests in the window, <m> traces read in <s> s, at <time>`, `<s>` the duration of the read of Jaeger with one decimal and `<time>` the time of the read, `HH:mm:ss`; with a source that cannot be read, its message after ` · `;
- after a read without Jaeger: `Jaeger cannot be reached: <reason>`, with the message of a source after ` · `;
- after a read that failed: the engine's message, in red, until a read succeeds.

The text of a read comes from the user; the other texts are design-time choices. Default chosen at design time.

## Sub projects

A sub project shows the Graph of the namespace of its own current working environment, which it inherits with its parent's environments while it uses its parent's settings. Its Graph opens focused on its own service: the service box named like the last component of the sub project's folder, its Deployment, when the graph has one; a right-click, or Show All, goes back to the whole namespace. A sub project whose folder names no service of the graph opens on the whole graph. The focus is taken when the section first shows a graph for the project in the window.

The opening on its own service comes from the user; the window's first graph as the moment of the focus is a design-time choice. Default chosen at design time.

## Remote devices

The windows of every device read the graph with [graph.read](engine-api.md#graphread) and a request with [graph.request](engine-api.md#graphrequest): kubectl, gh and the port forward to Jaeger run on the main device, with its kubeconfig files, its gh login and its network. The layout, the navigation and the views are computed in the window. The section's state, its window, its views opened, its texts and its request chosen, belongs to the window and is never synced.

## Requirements covered

- R192: A Go service project that enables its graph shows a Graph section of the Go Service category: the services, postgres Clusters and buckets of the namespace of its current working environment with the calls their sources declare, coloured by their number of calls in Jaeger over a time window, and the requests of that window, each with the boxes it went through, its timeline and its log lines, found by its correlation id.
