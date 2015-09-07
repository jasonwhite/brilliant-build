/**
 * Copyright: Copyright Jason White, 2015
 * License:   MIT
 * Authors:   Jason White
 *
 * Description:
 * Stores the persistent state of the build.
 */
module bb.state.sqlite;

import bb.vertex;
import bb.edge, bb.edgedata;
import sqlite3;

import std.typecons : tuple, Tuple;

/**
 * Table of resource vertices.
 */
private immutable resourcesTable = q"{
CREATE TABLE IF NOT EXISTS resource (
    id              INTEGER NOT NULL,
    path            TEXT    NOT NULL,
    lastModified    INTEGER NOT NULL,
    PRIMARY KEY (id),
    UNIQUE (path)
)}";

/**
 * Table of task vertices.
 */
private immutable tasksTable = q"{
CREATE TABLE IF NOT EXISTS task (
    id      INTEGER,
    command TEXT     NOT NULL,
    PRIMARY KEY(id),
    UNIQUE(command)
)}";

/**
 * Table of outgoing edges from resources.
 */
private immutable resourceEdgesTable = q"{
CREATE TABLE IF NOT EXISTS resourceEdge (
    id      INTEGER PRIMARY KEY,
    "from"  INTEGER NOT NULL REFERENCES resource(id),
    "to"    INTEGER NOT NULL REFERENCES task(id),
    type    INTEGER NOT NULL,
    UNIQUE("from", "to")
)}";

/**
 * Table of outgoing edges from tasks.
 */
private immutable taskEdgesTable = q"{
CREATE TABLE IF NOT EXISTS taskEdge (
    id      INTEGER PRIMARY KEY,
    "from"  INTEGER NOT NULL REFERENCES task(id),
    "to"    INTEGER NOT NULL REFERENCES resource(id),
    type    INTEGER NOT NULL,
    UNIQUE ("from", "to")
)}";

/**
 * Table of pending resources.
 */
private immutable pendingResourcesTable = q"{
CREATE TABLE IF NOT EXISTS pendingResources (
    resid INTEGER NOT NULL REFERENCES resource(id),
    UNIQUE (resid)
)}";

/**
 * Table of pending tasks.
 */
private immutable pendingTasksTable = q"{
CREATE TABLE IF NOT EXISTS pendingTasks (
    taskid INTEGER NOT NULL REFERENCES task(id),
    UNIQUE (taskid)
)}";

private immutable tables = [
    resourcesTable,
    tasksTable,
    resourceEdgesTable,
    taskEdgesTable,
    pendingResourcesTable,
    pendingTasksTable,
];

/**
 * Simple type to leverage the type system to differentiate between storage
 * indices.
 */
struct Index(T)
{
    ulong index;
    alias index this;
}

/**
 * Convenience type for an edge composed of two indices.
 */
alias Index(A, B) = Edge!(Index!A, Index!B);

/**
 * An edge row in the database.
 */
struct EdgeRow(A, B, EdgeData=EdgeType)
{
    Index!(A, B) edge;
    EdgeData data;
}

/**
 * Deserializes a vertex from a SQLite statement. This assumes that the
 * statement has every column of the vertex except the row ID.
 */
Vertex parse(Vertex : Resource)(SQLite3.Statement s)
{
    import std.datetime : SysTime;
    return Resource(s.get!string(0), SysTime(s.get!long(1)));
}

/// Ditto
Vertex parse(Vertex : Task)(SQLite3.Statement s)
{
    import std.conv : to;
    return Task(s.get!string(0).to!(string[]));
}

/**
 * Deserializes an edge from a SQLite statement. This assumes that the
 * statement has every column of the vertex except the row ID.
 */
E parse(E : EdgeRow!(Resource, Task))(SQLite3.Statement s)
{
    return E(
        Index!(Resource, Task)(
            Index!Resource(s.get!ulong(0)),
            Index!Task(s.get!ulong(1))
        ),
        cast(EdgeType)s.get!int(2)
        );
}

/// Ditto
E parse(E : EdgeRow!(Task, Resource))(SQLite3.Statement s)
{
    return E(
        Index!(Task, Resource)(
            Index!Task(s.get!ulong(0)),
            Index!Resource(s.get!ulong(1))
        ),
        cast(EdgeType)s.get!int(2)
        );
}

/**
 * Deserializes edge data.
 */
E parse(E : EdgeType)(SQLite3.Statement s)
{
    return cast(EdgeType)s.get!int(0);
}

/**
 * Deserializes an edge represented as a pair of identifiers.
 */
E parse(E : Edge!(ResourceId, TaskId))(SQLite3.Statement s)
{
    import std.conv : to;
    return E(s.get!string(0), s.get!string(1).to!(string[]));
}

/// Ditto
E parse(E : Edge!(TaskId, ResourceId))(SQLite3.Statement s)
{
    import std.conv : to;
    return E(s.get!string(0).to!(string[]), s.get!string(1));
}

/**
 * Stores the current state of the build.
 */
class BuildState : SQLite3
{
    /**
     * Open or create the build state file.
     */
    this(string fileName = ":memory:")
    {
        super(fileName);

        execute("PRAGMA foreign_keys = ON");

        createTables();
    }

    /**
     * Creates the tables if they don't already exist.
     */
    private void createTables()
    {
        begin();
        scope (success) commit();
        scope (failure) rollback();

        foreach (statement; tables)
            execute(statement);
    }

    /**
     * Inserts a vertex into the database. An exception is thrown if the vertex
     * already exists. Otherwise, the vertex's ID is returned.
     */
    Index!Resource put(in Resource resource)
    {
        execute("INSERT INTO resource(path, lastModified) VALUES(?, ?)",
                resource.path, resource.lastModified.stdTime);
        return Index!Resource(lastInsertId);
    }

    /// Ditto
    Index!Task put(in Task task)
    {
        import std.conv : to;

        execute("INSERT INTO task(command) VALUES(?)",
                task.command.to!string());

        return Index!Task(lastInsertId);
    }

    unittest
    {
        import std.datetime : SysTime;

        auto state = new BuildState;

        {
            immutable vertex = Resource("foo.c", SysTime(9001));

            auto id = state.put(vertex);
            assert(id == 1);
            assert(state[id] == vertex);
        }

        {
            immutable vertex = Task(["foo", "test", "test test"]);

            immutable id = state.put(vertex);
            assert(id == 1);
            assert(state[id] == vertex);
        }
    }

    /**
     * Removes a vertex by the given index. If the vertex does not exist, an
     * exception is thrown.
     */
    void remove(Index!Resource index)
    {
        execute("DELETE FROM resource WHERE id=?", index);
    }

    /// Ditto
    void remove(Index!Task index)
    {
        execute("DELETE FROM task WHERE id=?", index);
    }

    /**
     * Returns the vertex state at the given index.
     */
    Resource opIndex(Index!Resource index)
    {
        import std.exception : enforce;
        import std.datetime : SysTime;

        auto s = prepare("SELECT path,lastModified FROM resource WHERE id=?", index);
        enforce(s.step(), "Vertex does not exist.");

        return s.parse!Resource();
    }

    /// Ditto
    Task opIndex(Index!Task index)
    {
        import std.exception : enforce;

        auto s = prepare("SELECT command FROM task WHERE id=?", index);
        enforce(s.step(), "Vertex does not exist.");

        return s.parse!Task();
    }

    /**
     * Returns the vertex state for the given vertex name. Throws an exception if
     * the vertex does not exist.
     *
     * TODO: Only return the vertex's value.
     */
    Resource opIndex(ResourceId path)
    {
        import std.exception : enforce;
        import std.datetime : SysTime;

        auto s = prepare("SELECT path,lastModified FROM resource WHERE path=?", path);
        enforce(s.step(), "Vertex does not exist.");

        return s.parse!Resource();
    }

    /// Ditto
    Task opIndex(TaskId command)
    {
        import std.exception : enforce;
        import std.conv : to;

        auto s = prepare("SELECT command FROM task WHERE command=?", command.to!string);
        enforce(s.step(), "Vertex does not exist.");

        return s.parse!Task();
    }

    unittest
    {
        import std.datetime : SysTime;

        auto state = new BuildState;

        immutable vertex = Resource("foo.c", SysTime(9001));

        auto id = state.put(vertex);
        assert(id == 1);
        assert(state["foo.c"] == vertex);
    }

    unittest
    {
        auto state = new BuildState;

        immutable vertex = Task(["foo", "test", "test test"]);

        immutable id = state.put(vertex);
        assert(id == 1);
        assert(state[["foo", "test", "test test"]] == vertex);
    }

    /**
     * Changes the state of the vertex at the given index. Throws an exception if
     * the vertex does not exist.
     */
    void opIndexAssign(in Resource vertex, Index!Resource index)
    {
        execute(`UPDATE resource SET path=?,lastModified=? WHERE id=?`,
                vertex.path, vertex.lastModified.stdTime, index);
    }

    /// Ditto
    void opIndexAssign(in Task vertex, Index!Task index)
    {
        import std.conv : to;
        execute(`UPDATE task SET command=? WHERE id=?`,
                vertex.command.to!string, index);
    }

    /**
     * Returns an input range that iterates over all resources. The order is
     * guaranteed to be the same as the order they were inserted in.
     */
    @property auto vertices(Vertex : Resource)()
    {
        return prepare("SELECT path,lastModified FROM resource")
            .rows!(parse!Resource);
    }

    unittest
    {
        import std.algorithm : equal;
        import std.datetime : SysTime;

        auto state = new BuildState;

        immutable vertices = [
            Resource("foo.o", SysTime(42)),
            Resource("foo.c", SysTime(1337)),
            Resource("bar.c", SysTime(9001)),
            Resource("bar.o", SysTime(0)),
            ];

        foreach (vertex; vertices)
            state.put(vertex);

        assert(equal(vertices, state.vertices!Resource));
    }

    /**
     * Returns a sorted range of resource identifiers.
     */
    @property auto identifiers(Vertex : Resource)()
    {
        return prepare("SELECT path FROM resource ORDER BY path")
            .rows!((SQLite3.Statement s) => s.get!string(0));
    }

    unittest
    {
        import std.algorithm : equal, sort, map;

        auto state = new BuildState;

        auto vertices = [
            Resource("foo.o"),
            Resource("foo.c"),
            Resource("bar.c"),
            Resource("bar.o"),
            ];

        foreach (vertex; vertices)
            state.put(vertex);

        assert(equal(vertices.sort().map!(v => v.identifier), state.identifiers!Resource));
    }

    /**
     * Returns an input range that iterates over all resources in sorted
     * ascending order.
     */
    @property auto verticesSorted(Vertex : Resource)()
    {
        return prepare("SELECT path,lastModified FROM resource ORDER BY path")
            .rows!(parse!Resource);
    }

    unittest
    {
        import std.algorithm : equal, sort;
        import std.datetime : SysTime;

        auto state = new BuildState;

        auto vertices = [
            Resource("foo.o", SysTime(42)),
            Resource("foo.c", SysTime(1337)),
            Resource("bar.c", SysTime(9001)),
            Resource("bar.o", SysTime(0)),
            ];

        foreach (vertex; vertices)
            state.put(vertex);

        assert(equal(vertices.sort(), state.verticesSorted!Resource));
    }

    /**
     * Returns an input range that iterates over all tasks. The order is
     * guaranteed to be the same as the order they were inserted in.
     */
    @property auto vertices(Vertex : Task)()
    {
        return prepare("SELECT command FROM task")
            .rows!(parse!Task);
    }

    unittest
    {
        import std.algorithm : equal, sort;

        auto state = new BuildState;

        immutable tasks = [
            Task(["foo", "arg 1", "arg 2"]),
            Task(["bar", "arg 1"]),
            Task(["baz", "arg 1", "arg 2", "arg 3"]),
            ];

        foreach (task; tasks)
            state.put(task);

        assert(equal(tasks, state.vertices!Task));
    }

    /**
     * Returns an input range that iterates over all tasks in sorted ascending
     * order.
     */
    @property auto verticesSorted(Vertex : Task)()
    {
        import std.array : array;
        import std.algorithm : sort;

        // SQLite cannot correctly sort an array when that array is stored as a
        // string. Thus, we must sort it in D. This has the penalty of loading
        // all tasks into memory at once.
        return vertices!Vertex.array.sort();
    }

    unittest
    {
        import std.algorithm : equal, sort;

        auto state = new BuildState;

        auto vertices = [
            Task(["foo", "arg 1", "arg 2"]),
            Task(["bar", "arg 1"]),
            Task(["baz", "arg 1", "arg 2", "arg 3"]),
            ];

        foreach (vertex; vertices)
            state.put(vertex);

        assert(equal(vertices.sort(), state.verticesSorted!Task));
    }

    /**
     * Returns a sorted range of task identifiers.
     */
    @property auto identifiers(Vertex : Task)()
    {
        import std.conv : to;
        import std.array : array;
        import std.algorithm : sort;

        return prepare("SELECT command FROM task")
            .rows!(
                (SQLite3.Statement s) =>
                    cast(TaskId)(s.get!string(0).to!(string[]))
                )
            .array()
            .sort();
    }

    unittest
    {
        import std.algorithm : equal, map, sort;

        auto state = new BuildState;

        auto vertices = [
            Task(["z"]),
            Task(["b"]),
            Task(["a"]),
            Task(["c"]),
            Task(["q"]),
            ];

        foreach (vertex; vertices)
            state.put(vertex);

        assert(equal(vertices.sort().map!(v => v.identifier),
                    state.identifiers!Task));
    }

    /**
     * Adds an edge. Throws an exception if the edge already exists. Returns the
     * index of the edge.
     */
    Index!(Edge!(Resource, Task)) put(Index!(Resource, Task) edge, EdgeType type)
    {
        execute(`INSERT INTO resourceEdge("from", "to", type) VALUES(?, ?, ?)`,
                edge.from, edge.to, type);
        return typeof(return)(lastInsertId);
    }

    /// Ditto
    Index!(Edge!(Task, Resource)) put(Index!(Task, Resource) edge, EdgeType type)
    {
        execute(`INSERT INTO taskEdge("from", "to", type) VALUES(?, ?, ?)`,
                edge.from, edge.to, type);
        return typeof(return)(lastInsertId);
    }

    unittest
    {
        import std.exception : collectException;

        auto state = new BuildState;

        // Creating an edge to non-existent vertices should fail.
        immutable edge = Index!(Task, Resource)
            (Index!Task(4), Index!Resource(8));

        assert(collectException!SQLite3Exception(state.put(edge, EdgeType.explicit)));
    }

    unittest
    {
        auto state = new BuildState;

        // Create a couple of vertices to link together
        immutable resId = state.put(Resource("foo.c"));
        assert(resId == 1);

        immutable taskId = state.put(Task(["gcc", "foo.c"]));
        assert(taskId == 1);

        immutable edgeId = state.put(Index!(Resource, Task)(resId, taskId), EdgeType.explicit);
        assert(edgeId == 1);
    }

    /**
     * Removes an edge. Throws an exception if the edge does not exist.
     */
    void remove(Index!(Edge!(Resource, Task)) index)
    {
        execute(`DELETE FROM resourceEdge WHERE id=?`, index);
    }

    /// Ditto
    void remove(Index!(Edge!(Task, Resource)) index)
    {
        execute(`DELETE FROM taskEdge WHERE id=?`, index);
    }

    unittest
    {
        auto state = new BuildState;

        immutable resId  = state.put(Resource("foo.c"));
        immutable taskId = state.put(Task(["gcc", "foo.c"]));
        immutable edgeId = state.put(Index!(Resource, Task)(resId, taskId), EdgeType.explicit);
        state.remove(edgeId);
        state.remove(resId);
        state.remove(taskId);
    }

    /**
     * Gets the state associated with an edge.
     */
    EdgeRow!(Task, Resource) opIndex(Index!(Edge!(Task, Resource)) index)
    {
        import std.exception : enforce;

        auto s = prepare(
            `SELECT "from","to","type" FROM taskEdge WHERE id=?`, index);
        enforce(s.step(), "Edge does not exist.");

        return s.parse!(typeof(return));
    }

    /// Ditto
    EdgeRow!(Resource, Task) opIndex(Index!(Edge!(Resource, Task)) index)
    {
        import std.exception : enforce;

        auto s = prepare(
            `SELECT "from","to","type" FROM resourceEdge WHERE id=?`, index);
        enforce(s.step(), "Edge does not exist.");

        return s.parse!(typeof(return));
    }

    /// Ditto
    EdgeType opIndex(Index!Task from, Index!Resource to)
    {
        import std.exception : enforce;

        auto s = prepare(
            `SELECT "type" FROM taskEdge WHERE "from"=? AND "to"=?`, from, to);
        enforce(s.step(), "Edge does not exist.");

        return s.parse!(typeof(return));
    }

    /// Ditto
    EdgeType opIndex(Index!Resource from, Index!Task to)
    {
        import std.exception : enforce;

        auto s = prepare(
            `SELECT "type" FROM resourceEdge WHERE "from"=? AND "to"=?`,
            from, to);
        enforce(s.step(), "Edge does not exist.");

        return s.parse!(typeof(return));
    }

    /// Ditto
    EdgeType opIndex(Index!(Resource, Task) edge)
    {
        return opIndex(edge.from, edge.to);
    }

    /// Ditto
    EdgeType opIndex(Index!(Task, Resource) edge)
    {
        return opIndex(edge.from, edge.to);
    }

    /**
     * Lists all outgoing task edges.
     */
    @property auto edges(From : Task, To : Resource)()
    {
        return prepare(`SELECT "from","to","type" FROM taskEdge`)
            .rows!(parse!(EdgeRow!(From, To)));
    }

    /// Ditto
    @property auto edgesSorted(From : Task, To : Resource)()
    {
        return prepare(
            `SELECT "from","to","type" FROM taskEdge ORDER BY "from","to"`)
            .rows!(parse!(EdgeRow!(From, To)));
    }

    /**
     * Lists all outgoing resource edges.
     */
    @property auto edges(From : Resource, To : Task)()
    {
        return prepare(`SELECT "from","to","type" FROM resourceEdge`)
            .rows!(parse!(EdgeRow!(From, To)));
    }

    /// Ditto
    @property auto edgesSorted(From : Resource, To : Task)()
    {
        return prepare(
            `SELECT "from","to","type" FROM resourceEdge ORDER BY "from","to"`)
            .rows!(parse!(EdgeRow!(From, To)));
    }

    /**
     * Returns a range of edges as pairs of identifiers.
     */
    @property auto edgeIdentifiers(From : ResourceId, To : TaskId)()
    {
        return prepare(
            `SELECT resource.path, task.command`
            ` FROM resourceEdge AS e`
            ` JOIN task ON e."from"=resource.id`
            ` JOIN resource ON e."to"=task.id`
            ).rows!(parse!(Edge!(From, To)));
    }

    /// Ditto
    @property auto edgeIdentifiers(From : TaskId, To : ResourceId)()
    {
        return prepare(
            `SELECT task.command, resource.path`
            ` FROM taskEdge AS e`
            ` JOIN resource ON e."from"=task.id`
            ` JOIN task ON e."to"=resource.id`
            ).rows!(parse!(Edge!(From, To)));
    }

    /// Ditto
    @property auto edgeIdentifiersSorted(From : ResourceId, To : TaskId)()
    {
        import std.array : array;
        import std.algorithm : sort;

        return prepare(
            `SELECT resource.path, task.command`
            ` FROM resourceEdge AS e`
            ` JOIN task ON e."from"=resource.id`
            ` JOIN resource ON e."to"=task.id`)
            .rows!(parse!(Edge!(From, To)))
            .array
            .sort();
    }

    /// Ditto
    @property auto edgeIdentifiersSorted(From : TaskId, To : ResourceId)()
    {
        import std.array : array;
        import std.algorithm : sort;

        return prepare(
            `SELECT task.command, resource.path`
            ` FROM taskEdge AS e`
            ` JOIN resource ON e."from"=task.id`
            ` JOIN task ON e."to"=resource.id`
            ` ORDER BY task.command, resource.path`)
            .rows!(parse!(Edge!(From, To)))
            .array
            .sort();
    }

    unittest
    {
        import std.algorithm : map, equal;
        import std.array : array;

        auto state = new BuildState;

        auto resources = [
            // Inputs
            Resource("foo.c"),
            Resource("bar.c"),

            // Outputs
            Resource("foo.o"),
            Resource("bar.o"),
            Resource("foobar"),
            ];
        auto resourceIds = resources.map!(r => state.put(r)).array;

        auto tasks = [
            Task(["gcc", "foo.c"]),
            Task(["gcc", "bar.c"]),
            Task(["gcc", "foo.o", "bar.o", "-o", "foobar"]),
            ];
        auto taskIds = tasks.map!(t => state.put(t)).array;

        alias EIRT = Index!(Resource, Task);
        alias EITR = Index!(Task, Resource);

        state.put(EIRT(resourceIds[0], taskIds[0]), EdgeType.explicit);
        state.put(EIRT(resourceIds[1], taskIds[1]), EdgeType.explicit);
        state.put(EIRT(resourceIds[2], taskIds[2]), EdgeType.explicit);
        state.put(EIRT(resourceIds[3], taskIds[2]), EdgeType.explicit);

        state.put(EITR(taskIds[0], resourceIds[2]), EdgeType.explicit);
        state.put(EITR(taskIds[1], resourceIds[3]), EdgeType.explicit);
        state.put(EITR(taskIds[2], resourceIds[4]), EdgeType.explicit);

        // Edges should come out in the same order as they are inserted
        assert(equal(state.edgeIdentifiers!(ResourceId, TaskId), [
            Edge!(ResourceId, TaskId)("foo.c", ["gcc", "foo.c"]),
            Edge!(ResourceId, TaskId)("bar.c", ["gcc", "bar.c"]),
            Edge!(ResourceId, TaskId)("foo.o", ["gcc", "foo.o", "bar.o", "-o", "foobar"]),
            Edge!(ResourceId, TaskId)("bar.o", ["gcc", "foo.o", "bar.o", "-o", "foobar"]),
            ]));
        assert(equal(state.edgeIdentifiers!(TaskId, ResourceId), [
            Edge!(TaskId, ResourceId)(["gcc", "foo.c"], "foo.o"),
            Edge!(TaskId, ResourceId)(["gcc", "bar.c"], "bar.o"),
            Edge!(TaskId, ResourceId)(["gcc", "foo.o", "bar.o", "-o", "foobar"], "foobar"),
            ]));

        // Edges should be sorted by their identifiers
        assert(equal(state.edgeIdentifiersSorted!(ResourceId, TaskId), [
            Edge!(ResourceId, TaskId)("bar.c", ["gcc", "bar.c"]),
            Edge!(ResourceId, TaskId)("bar.o", ["gcc", "foo.o", "bar.o", "-o", "foobar"]),
            Edge!(ResourceId, TaskId)("foo.c", ["gcc", "foo.c"]),
            Edge!(ResourceId, TaskId)("foo.o", ["gcc", "foo.o", "bar.o", "-o", "foobar"]),
            ]));
        assert(equal(state.edgeIdentifiersSorted!(TaskId, ResourceId), [
            Edge!(TaskId, ResourceId)(["gcc", "bar.c"], "bar.o"),
            Edge!(TaskId, ResourceId)(["gcc", "foo.c"], "foo.o"),
            Edge!(TaskId, ResourceId)(["gcc", "foo.o", "bar.o", "-o", "foobar"], "foobar"),
            ]));
    }

    /**
     * Adds a vertex to the list of pending vertices. If the vertex is already
     * pending, nothing is done.
     */
    void addPending(Vertex : Resource)(Index!Vertex v)
    {
        execute(`INSERT OR IGNORE INTO pendingResources(resid) VALUES(?)`, v);
    }

    /// Ditto
    void addPending(Vertex : Task)(Index!Vertex v)
    {
        execute(`INSERT OR IGNORE INTO pendingTasks(taskid) VALUES(?)`, v);
    }

    /**
     * Removes a pending vertex.
     */
    void removePending(Vertex : Resource)(Index!Vertex v)
    {
        execute("DELETE FROM pendingResources WHERE resid=?", v);
    }

    /// Ditto
    void removePending(Vertex : Task)(Index!Vertex v)
    {
        execute("DELETE FROM pendingTasks WHERE taskid=?", v);
    }

    /**
     * Lists the pending vertices.
     */
    @property auto pending(Vertex : Resource)()
    {
        return prepare("SELECT resid FROM pendingResources")
            .rows!((SQLite3.Statement s) => Index!Vertex(s.get!ulong(0)));
    }

    /// Ditto
    @property auto pending(Vertex : Task)()
    {
        return prepare("SELECT taskid FROM pendingTasks")
            .rows!((SQLite3.Statement s) => Index!Vertex(s.get!ulong(0)));
    }
}
