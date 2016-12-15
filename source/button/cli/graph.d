/**
 * Copyright: Copyright Jason White, 2016
 * License:   MIT
 * Authors:   Jason White
 *
 * Description:
 * Generates input for GraphViz.
 */
module button.cli.graph;

import button.cli.options : GraphOptions, GlobalOptions;

import io.text,
       io.file;

import io.stream : isSink;

import button.resource,
       button.task,
       button.edgedata,
       button.graph,
       button.state,
       button.build,
       button.exceptions;

int graphCommand(GraphOptions opts, GlobalOptions globalOpts)
{
    import std.array : array;
    import std.algorithm.iteration : filter;
    import std.parallelism : TaskPool, totalCPUs;

    if (opts.threads == 0)
        opts.threads = totalCPUs;

    auto pool = new TaskPool(opts.threads - 1);
    scope (exit) pool.finish(true);

    try
    {
        string path = buildDescriptionPath(opts.path);

        auto state = new BuildState(path.stateName);

        state.begin();
        scope (exit) state.rollback();

        if (!opts.cached)
            path.syncState(state, pool, true);

        BuildStateGraph graph = state.buildGraph(opts.edges);

        if (opts.changes)
        {
            // Construct the minimal subgraph based on pending vertices
            auto resourceRoots = state.enumerate!(Index!Resource)
                .filter!(v => state.degreeIn(v) == 0 && state[v].update())
                .array;

            auto taskRoots = state.pending!Task
                .filter!(v => state.degreeIn(v) == 0)
                .array;

            graph = graph.subgraph(resourceRoots, taskRoots);
        }

        graph.graphviz(state, stdout, opts.full);
    }
    catch (BuildException e)
    {
        stderr.println(":: Error: ", e.msg);
        return 1;
    }

    return 0;
}

/**
 * Escape a label string to be consumed by GraphViz.
 */
private string escapeLabel(string label) pure
{
    import std.array : appender;
    import std.exception : assumeUnique;

    auto result = appender!(char[]);

    foreach (c; label)
    {
        if (c == '\\' || c == '"')
            result.put('\\');
        result.put(c);
    }

    return assumeUnique(result.data);
}

unittest
{
    assert(escapeLabel(`gcc -c "foo.c"`) == `gcc -c \"foo.c\"`);
}

/**
 * Generates input suitable for GraphViz.
 */
void graphviz(Stream)(
        BuildStateGraph graph,
        BuildState state,
        Stream stream,
        bool full
        )
    if (isSink!Stream)
{
    import io.text;
    import std.range : enumerate;

    alias A = Index!Resource;
    alias B = Index!Task;

    stream.println("digraph G {");
    scope (success) stream.println("}");

    // Vertices
    stream.println("    subgraph {\n" ~
                   "        node [shape=ellipse, fillcolor=lightskyblue2, style=filled];"
            );
    foreach (id; graph.vertices!A)
    {
        immutable v = state[id];
        immutable name = full ? v.toString : v.toShortString;
        stream.printfln(`        "r:%s" [label="%s", tooltip="%s"];`, id,
                name.escapeLabel, v.toString.escapeLabel);
    }
    stream.println("    }");

    stream.println("    subgraph {\n" ~
                   "        node [shape=box, fillcolor=gray91, style=filled];"
            );
    foreach (id; graph.vertices!B)
    {
        immutable v = state[id];
        immutable name = full ? v.toPrettyString : v.toPrettyShortString;
        stream.printfln(`        "t:%s" [label="%s", tooltip="%s"];`, id,
                name.escapeLabel, v.toPrettyString.escapeLabel);
    }
    stream.println("    }");

    // Cluster cycles, if any
    foreach (i, scc; enumerate(graph.cycles))
    {
        stream.printfln("    subgraph cluster_%d {", i++);

        foreach (v; scc.vertices!A)
            stream.printfln(`        "r:%s";`, v);

        foreach (v; scc.vertices!B)
            stream.printfln(`        "t:%s";`, v);

        stream.println("    }");
    }

    // Edge style, indexed by EdgeType.
    static immutable styles = [
        "invis",  // Should never get indexed
        "solid",  // Explicit
        "dashed", // Implicit
        "bold",   // Both explicit and implicit
    ];

    // Edges
    foreach (edge; graph.edges!(A, B))
    {
        stream.printfln(`    "r:%s" -> "t:%s" [style=%s];`,
                edge.from, edge.to, styles[edge.data]);
    }

    foreach (edge; graph.edges!(B, A))
    {
        stream.printfln(`    "t:%s" -> "r:%s" [style=%s];`,
                edge.from, edge.to, styles[edge.data]);
    }
}

/// Ditto
void graphviz(Stream)(Graph!(Resource, Task) graph, Stream stream)
    if (isSink!Stream)
{
    import io.text;
    import std.range : enumerate;

    alias A = Resource;
    alias B = Task;

    stream.println("digraph G {");
    scope (success) stream.println("}");

    // Vertices
    stream.println("    subgraph {\n" ~
                   "        node [shape=ellipse, fillcolor=lightskyblue2, style=filled];"
            );
    foreach (v; graph.vertices!Resource)
    {
        stream.printfln(`        "r:%s"`, v.escapeLabel);
    }
    stream.println("    }");

    stream.println("    subgraph {\n" ~
                   "        node [shape=box, fillcolor=gray91, style=filled];"
            );
    foreach (v; graph.vertices!Task)
    {
        stream.printfln(`        "t:%s"`, v.escapeLabel);
    }
    stream.println("    }");

    // Cluster cycles, if any
    foreach (i, scc; enumerate(graph.cycles))
    {
        stream.printfln("    subgraph cluster_%d {", i++);

        foreach (v; scc.vertices!Resource)
            stream.printfln(`        "r:%s";`, v.escapeLabel);

        foreach (v; scc.vertices!Task)
            stream.printfln(`        "t:%s";`, v.escapeLabel);

        stream.println("    }");
    }

    // Edges
    // TODO: Style as dashed edge if implicit edge
    foreach (edge; graph.edges!(Resource, Task))
        stream.printfln(`    "r:%s" -> "t:%s";`,
                edge.from.escapeLabel, edge.to.escapeLabel);

    foreach (edge; graph.edges!(Task, Resource))
        stream.printfln(`    "t:%s" -> "r:%s";`,
                edge.from.escapeLabel, edge.to.escapeLabel);
}
