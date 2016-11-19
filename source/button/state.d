/**
 * Copyright: Copyright Jason White, 2016
 * License:   MIT
 * Authors:   Jason White
 *
 * Description:
 * Stores the persistent state of the build.
 */
module button.state;

import button.command;
import button.resource;
import button.task;
import button.edge, button.edgedata;
import util.sqlite3;

import std.typecons : tuple, Tuple;

/**
 * Table of resource vertices.
 *
 * The first entry in this table will always be the build description.
 */
private immutable resourcesTable = q"{
CREATE TABLE IF NOT EXISTS resource (
    id              INTEGER NOT NULL,
    path            TEXT    NOT NULL,
    status          INTEGER NOT NULL,
    checksum        BLOB    NOT NULL,
    PRIMARY KEY (id),
    UNIQUE (path)
)}";

/**
 * Table of task vertices.
 */
private immutable tasksTable = q"{
CREATE TABLE IF NOT EXISTS task (
    id           INTEGER,
    commands     TEXT     NOT NULL,
    workDir      TEXT     NOT NULL,
    display      TEXT,
    lastExecuted INTEGER  NOT NULL,
    PRIMARY KEY(id),
    UNIQUE(commands, workDir)
)}";

/**
 * Table of outgoing edges from resources.
 */
private immutable resourceEdgesTable = q"{
CREATE TABLE IF NOT EXISTS resourceEdge (
    id      INTEGER PRIMARY KEY,
    "from"  INTEGER NOT NULL REFERENCES resource(id) ON DELETE CASCADE,
    "to"    INTEGER NOT NULL REFERENCES task(id) ON DELETE CASCADE,
    type    INTEGER NOT NULL,
    UNIQUE("from", "to", type)
)}";

/**
 * Table of outgoing edges from tasks.
 */
private immutable taskEdgesTable = q"{
CREATE TABLE IF NOT EXISTS taskEdge (
    id      INTEGER PRIMARY KEY,
    "from"  INTEGER NOT NULL REFERENCES task(id) ON DELETE CASCADE,
    "to"    INTEGER NOT NULL REFERENCES resource(id) ON DELETE CASCADE,
    type    INTEGER NOT NULL,
    UNIQUE ("from", "to", type)
)}";

/**
 * Table of pending resources.
 */
private immutable pendingResourcesTable = q"{
CREATE TABLE IF NOT EXISTS pendingResources (
    resid INTEGER NOT NULL REFERENCES resource(id) ON DELETE CASCADE,
    PRIMARY KEY (resid),
    UNIQUE (resid)
)}";

/**
 * Table of pending tasks.
 */
private immutable pendingTasksTable = q"{
CREATE TABLE IF NOT EXISTS pendingTasks (
    taskid INTEGER NOT NULL REFERENCES task(id) ON DELETE CASCADE,
    PRIMARY KEY (taskid),
    UNIQUE (taskid)
)}";

/**
 * Index on vertex keys to speed up searches.
 */
private immutable resourceIndex = q"{
CREATE INDEX IF NOT EXISTS resourceIndex ON resource(path)
}";

/// Ditto
private immutable taskIndex = q"{
CREATE INDEX IF NOT EXISTS taskIndex ON task(commands,workDir)
}";

/**
 * Index on edges to speed up finding neighbors.
 */
private immutable resourceEdgeIndex = q"{
CREATE INDEX IF NOT EXISTS resourceEdgeIndex ON resourceEdge("from","to")
}";

/// Ditto
private immutable taskEdgeIndex = q"{
CREATE INDEX IF NOT EXISTS taskEdgeIndex ON taskEdge("from","to")
}";

/**
 * List of SQL statements to run in order to initialize the database.
 */
private immutable initializeStatements = [
    // Create tables
    resourcesTable,
    tasksTable,
    resourceEdgesTable,
    taskEdgesTable,
    pendingResourcesTable,
    pendingTasksTable,

    // Indiees
    resourceEdgeIndex,
    taskEdgeIndex,
    resourceIndex,
    taskIndex,
];

/**
 * Simple type to leverage the type system to help to differentiate between
 * storage indices.
 */
struct Index(T)
{
    ulong index;
    alias index this;

    /// An invalid index.
    enum Invalid = Index!T(0);
}

/**
 * Convenience type for an edge composed of two indices.
 */
alias Index(A, B) = Edge!(Index!A, Index!B);

/**
 * Convenience type for an index of the edge itself.
 */
alias EdgeIndex(A, B) = Index!(Edge!(A, B));

/**
 * An edge row in the database.
 */
alias EdgeRow(A, B, Data=EdgeType) = Edge!(Index!A, Index!B, Data);

/**
 * A vertex paired with some data. This is useful for representing a neighbor.
 */
struct Neighbor(Vertex, Data)
{
    Vertex vertex;
    Data data;
}

/**
 * Convenience templates to get the other type of vertex from the given vertex.
 */
alias Other(A : Resource) = Task;
alias Other(A : Task) = Resource; /// Ditto

/**
 * Convenience template to construct an edge from the starting vertex.
 */
alias NeighborIndex(V : Index!V) = EdgeIndex!(V, Other!V);

/**
 * Thrown when an edge does not exist.
 */
class InvalidEdge : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, file, line);
    }
}

/**
 * Deserializes a vertex from a SQLite statement. This assumes that the
 * statement has every column of the vertex except the row ID.
 */
Vertex parse(Vertex : Resource)(SQLite3.Statement s)
{
    return Resource(
            s.get!string(0), // Path
            cast(Resource.Status)s.get!long(1), // Status
            cast(ubyte[])s.get!(void[])(2) // Checksum
            );
}

/// Ditto
Vertex parse(Vertex : Task)(SQLite3.Statement s)
{
    import std.conv : to;
    import std.datetime : SysTime;
    import std.algorithm.iteration : map;
    import std.array : array;
    import std.exception : assumeUnique;

    return Task(
        s.get!string(0)
            .to!(string[][])
            .map!(x => Command(x.assumeUnique))
            .array
            .assumeUnique,
        s.get!string(1),
        s.get!string(2),
        SysTime(s.get!long(3)),
        );
}

/**
 * Deserializes an edge from a SQLite statement. This assumes that the
 * statement has every column of the vertex except the row ID.
 */
E parse(E : EdgeRow!(Resource, Task, EdgeType))(SQLite3.Statement s)
{
    return E(
        Index!Resource(s.get!ulong(0)),
        Index!Task(s.get!ulong(1)),
        cast(EdgeType)s.get!int(2)
        );
}

/// Ditto
E parse(E : EdgeRow!(Task, Resource, EdgeType))(SQLite3.Statement s)
{
    return E(
        Index!Task(s.get!ulong(0)),
        Index!Resource(s.get!ulong(1)),
        cast(EdgeType)s.get!int(2)
        );
}

/// Ditto
E parse(E : EdgeRow!(Resource, Task, EdgeIndex!(Resource, Task)))(SQLite3.Statement s)
{
    return E(
        Index!Resource(s.get!ulong(0)),
        Index!Task(s.get!ulong(1)),
        cast(EdgeIndex!(Resource, Task))s.get!int(2)
        );
}

/// Ditto
E parse(E : EdgeRow!(Task, Resource, EdgeIndex!(Task, Resource)))(SQLite3.Statement s)
{
    return E(
        Index!Task(s.get!ulong(0)),
        Index!Resource(s.get!ulong(1)),
        cast(EdgeIndex!(Task, Resource))s.get!int(2)
        );
}

/**
 * Parses an edge without the associated data.
 */
E parse(E : Index!(Resource, Task))(SQLite3.Statement s)
{
    return E(Index!Resource(s.get!ulong(0)), Index!Task(s.get!ulong(1)));
}

/// Ditto
E parse(E : Index!(Task, Resource))(SQLite3.Statement s)
{
    return E(Index!Task(s.get!ulong(0)), Index!Resource(s.get!ulong(1)));
}

/**
 * Deserializes edge data.
 */
E parse(E : EdgeType)(SQLite3.Statement s)
{
    return cast(EdgeType)s.get!int(0);
}

/**
 * Deserializes a neighbor.
 */
E parse(E : Neighbor!(Index!Resource, EdgeType))(SQLite3.Statement s)
{
    return E(
        Index!Resource(s.get!ulong(0)),
        cast(EdgeType)s.get!int(1)
        );
}

/// Ditto
E parse(E : Neighbor!(Index!Task, EdgeType))(SQLite3.Statement s)
{
    return E(
        Index!Task(s.get!ulong(0)),
        cast(EdgeType)s.get!int(1)
        );
}

/// Ditto
E parse(E : Neighbor!(Index!Resource, EdgeIndex!(Task, Resource)))(SQLite3.Statement s)
{
    return E(
        Index!Resource(s.get!ulong(0)),
        EdgeIndex!(Task, Resource)(s.get!ulong(1))
        );
}

/// Ditto
E parse(E : Neighbor!(Index!Task, EdgeIndex!(Resource, Task)))(SQLite3.Statement s)
{
    return E(
        Index!Task(s.get!ulong(0)),
        EdgeIndex!(Resource, Task)(s.get!ulong(1))
        );
}

/**
 * Parses a vertex key.
 */
E parse(E : ResourceKey)(SQLite3.Statement s)
{
    return E(
        s.get!string(0)
        );
}

/// Ditto
E parse(E : TaskKey)(SQLite3.Statement s)
{
    import std.conv : to;
    import std.algorith.iteration : map;
    import std.array : array;
    import std.exception : assumeUnique;

    return E(
        s.get!string(0)
            .to!(string[][])
            .map!(x => Command(x.assumeUnique))
            .array
            .assumeUnique,
        s.get!string(1)
        );
}

/**
 * Stores the current state of the build.
 */
class BuildState : SQLite3
{
    // The build description is always the first entry in the database.
    static immutable buildDescId = Index!Resource(1);

    private
    {
        Statement sqlInsertResource;
        Statement sqlInsertTask;

        Statement sqlAddResource;
        Statement sqlAddTask;

        Statement sqlRemoveResourceByIndex;
        Statement sqlRemoveTaskByIndex;

        Statement sqlRemoveResourceByKey;
        Statement sqlRemoveTaskByKey;

        Statement sqlFindResourceByKey;
        Statement sqlFindTaskByKey;

        Statement sqlResourceByIndex;
        Statement sqlTaskByIndex;

        Statement sqlResourceByKey;
        Statement sqlTaskByKey;

        Statement sqlUpdateResource;
        Statement sqlUpdateTask;

        Statement sqlInsertTaskEdge;
        Statement sqlInsertResourceEdge;
        Statement sqlRemoveTaskEdge;
        Statement sqlRemoveResourceEdge;

        Statement sqlResourceDegreeIn;
        Statement sqlTaskDegreeIn;
        Statement sqlResourceDegreeOut;
        Statement sqlTaskDegreeOut;

        Statement sqlResourceEdgeExists;
        Statement sqlTaskEdgeExists;

        Statement sqlAddPendingResource;
        Statement sqlAddPendingTask;
        Statement sqlRemovePendingResource;
        Statement sqlRemovePendingTask;
        Statement sqlIsPendingResource;
        Statement sqlIsPendingTask;
    }

    /**
     * Open or create the build state file.
     */
    this(string fileName = ":memory:")
    {
        super(fileName);

        execute("PRAGMA foreign_keys = ON");

        initialize();
    }

    /**
     * Creates the tables if they don't already exist.
     */
    private void initialize()
    {
        begin();
        scope (success) commit();
        scope (failure) rollback();

        foreach (statement; initializeStatements)
            execute(statement);

        // Add the build description resource if it doesn't already exist.
        execute(
            `INSERT OR IGNORE INTO resource` ~
            `    (id,path,status,checksum)` ~
            `    VALUES (?,?,?,?)`
            , buildDescId, "", 0, 0
            );

        // Prepare SQL statements. This is much faster than preparing +
        // executing statements for every query. For queries that only run once,
        // it is not necessary to prepare them here.
        sqlInsertResource = new Statement(
                `INSERT INTO resource(path, status, checksum)` ~
                ` VALUES(?, ?, ?)`
                );
        sqlInsertTask = new Statement(
                `INSERT INTO task (commands, workDir, display, lastExecuted)` ~
                ` VALUES(?, ?, ?, ?)`
                );
        sqlAddResource = new Statement(
                `INSERT OR IGNORE INTO resource` ~
                ` (path, status, checksum)` ~
                ` VALUES(?, ?, ?)`
                );
        sqlAddTask = new Statement(
                `INSERT OR IGNORE INTO task` ~
                ` (commands, workDir, display, lastExecuted)` ~
                ` VALUES(?, ?, ?, ?)`
                );
        sqlRemoveResourceByIndex = new Statement(
                `DELETE FROM resource WHERE id=?`
                );
        sqlRemoveTaskByIndex = new Statement(
                `DELETE FROM task WHERE id=?`
                );
        sqlRemoveResourceByKey = new Statement(
                `DELETE FROM resource WHERE path=?`
                );
        sqlRemoveTaskByKey = new Statement(
                `DELETE FROM task WHERE commands=? AND workDir=?`
                );
        sqlFindResourceByKey = new Statement(
                `SELECT id FROM resource WHERE path=?`
                );
        sqlFindTaskByKey = new Statement(
                `SELECT id FROM task WHERE commands=? AND workDir=?`
                );
        sqlResourceByIndex = new Statement(
                `SELECT path,status,checksum` ~
                ` FROM resource WHERE id=?`
                );
        sqlTaskByIndex = new Statement(
                `SELECT commands,workDir,display,lastExecuted` ~
                ` FROM task WHERE id=?`
                );
        sqlResourceByKey = new Statement(
               `SELECT path,status,checksum` ~
               ` FROM resource WHERE path=?`
                );
        sqlTaskByKey = new Statement(
                `SELECT commands,workDir,display,lastExecuted FROM task` ~
                ` WHERE commands=? AND workDir=?`
                );
        sqlUpdateResource = new Statement(
                `UPDATE resource` ~
                ` SET path=?,status=?,checksum=?` ~
                ` WHERE id=?`
                );
        sqlUpdateTask = new Statement(
               `UPDATE task` ~
               ` SET commands=?,workDir=?,display=?,lastExecuted=?` ~
               ` WHERE id=?`
                );
        sqlInsertTaskEdge = new Statement(
                `INSERT INTO taskEdge("from", "to", type) VALUES(?, ?, ?)`
                );
        sqlInsertResourceEdge = new Statement(
                `INSERT INTO resourceEdge("from", "to", type)` ~
                ` VALUES(?, ?, ?)`
                );
        sqlRemoveTaskEdge = new Statement(
                `DELETE FROM taskEdge WHERE "from"=? AND "to"=? AND type=?`
                );
        sqlRemoveResourceEdge = new Statement(
                `DELETE FROM resourceEdge WHERE "from"=? AND "to"=? AND type=?`
                );
        sqlResourceDegreeIn = new Statement(
                `SELECT COUNT("to") FROM taskEdge WHERE "to"=?`
                );
        sqlTaskDegreeIn = new Statement(
                `SELECT COUNT("to") FROM resourceEdge WHERE "to"=?`
                );
        sqlResourceDegreeOut = new Statement(
                `SELECT COUNT("to") FROM resourceEdge WHERE "from"=?`
                );
        sqlTaskDegreeOut = new Statement(
                `SELECT COUNT("to") FROM taskEdge WHERE "from"=?`
                );
        sqlResourceEdgeExists = new Statement(
                `SELECT "type" FROM resourceEdge` ~
                ` WHERE "from"=? AND "to"=? AND type=?`
                );
        sqlTaskEdgeExists = new Statement(
                `SELECT "type" FROM taskEdge WHERE` ~
                ` "from"=? AND "to"=? AND type=?`
                );
        sqlAddPendingResource = new Statement(
                `INSERT OR IGNORE INTO pendingResources(resid) VALUES(?)`
                );
        sqlAddPendingTask = new Statement(
                `INSERT OR IGNORE INTO pendingTasks(taskid) VALUES(?)`
                );
        sqlRemovePendingResource = new Statement(
                `DELETE FROM pendingResources WHERE resid=?`
                );
        sqlRemovePendingTask = new Statement(
                `DELETE FROM pendingTasks WHERE taskid=?`
                );
        sqlIsPendingResource = new Statement(
                `SELECT EXISTS(` ~
                ` SELECT 1 FROM pendingResources WHERE resid=? LIMIT 1` ~
                `)`
                );
        sqlIsPendingTask = new Statement(
                `SELECT EXISTS(` ~
                ` SELECT 1 FROM pendingTasks WHERE taskid=? LIMIT 1`~
                `)`
                );
    }

    /**
     * Returns the number of vertices in the database.
     */
    ulong length(Vertex : Resource)()
    {
        import std.exception : enforce;
        auto s = prepare(`SELECT COUNT(*) FROM resource WHERE id > 1`);
        enforce(s.step(), "Failed to find number of resources");
        return s.get!ulong(0);
    }

    /// Dito
    ulong length(Vertex : Task)()
    {
        import std.exception : enforce;
        auto s = prepare(`SELECT COUNT(*) FROM task`);
        enforce(s.step(), "Failed to find number of tasks");
        return s.get!ulong(0);
    }

    /**
     * Inserts a vertex into the database. An exception is thrown if the vertex
     * already exists. Otherwise, the vertex's ID is returned.
     */
    Index!Resource put(in Resource resource)
    {
        alias s = sqlInsertResource;

        synchronized (s)
        {
            scope (exit) s.reset();

            s.bind(resource.path,
                   resource.status,
                   resource.checksum);
            s.step();
        }

        return Index!Resource(lastInsertId);
    }

    /// Ditto
    Index!Task put(in Task task)
    {
        import std.conv : to;

        alias s = sqlInsertTask;

        synchronized (s)
        {
            scope (exit) s.reset();

            s.bind(task.commands.to!string(),
                   task.workingDirectory,
                   task.display,
                   task.lastExecuted.stdTime);
            s.step();
        }

        return Index!Task(lastInsertId);
    }

    unittest
    {
        auto state = new BuildState;

        {
            immutable vertex = Resource("foo.c", Resource.Status.file);

            auto id = state.put(vertex);
            assert(state[id] == vertex);
        }

        {
            immutable vertex = Task([Command(["foo", "test", "test test"])]);

            immutable id = state.put(vertex);
            assert(state[id] == vertex);
        }
    }

    /**
     * Inserts a vertex into the database unless it already exists.
     */
    void add(in Resource resource)
    {
        alias s = sqlAddResource;

        synchronized (s)
        {
            scope (exit) s.reset();

            s.bind(resource.path,
                   resource.status,
                   resource.checksum);
            s.step();
        }
    }

    // Ditto
    void add(in Task task)
    {
        import std.conv : to;

        alias s = sqlAddTask;

        synchronized (s)
        {
            scope (exit) s.reset();

            s.bind(task.commands.to!string(),
                   task.workingDirectory,
                   task.display,
                   task.lastExecuted.stdTime);
            s.step();
        }
    }

    /**
     * Removes a vertex by the given index. If the vertex does not exist, an
     * exception is thrown.
     */
    void remove(Index!Resource index)
    {
        alias s = sqlRemoveResourceByIndex;

        synchronized (s)
        {
            scope (exit) s.reset();
            s.bind(index);
            s.step();
        }
    }

    /// Ditto
    void remove(Index!Task index)
    {
        alias s = sqlRemoveTaskByIndex;

        synchronized (s)
        {
            scope (exit) s.reset();
            s.bind(index);
            s.step();
        }
    }

    /// Ditto
    void remove(ResourceId path)
    {
        alias s = sqlRemoveResourceByKey;

        synchronized (s)
        {
            scope (exit) s.reset();
            s.bind(path);
            s.step();
        }
    }

    /// Ditto
    void remove(TaskKey key)
    {
        import std.conv : to;

        alias s = sqlRemoveTaskByKey;

        synchronized (s)
        {
            scope (exit) s.reset();
            s.bind(key.commands.to!string, key.workingDirectory);
            s.step();
        }
    }

    /**
     * Returns the index of the given vertex.
     */
    Index!Resource find(const(char)[] key)
    {
        alias s = sqlFindResourceByKey;

        synchronized (s)
        {
            scope (exit) s.reset();

            s.bind(key);

            if (s.step())
                return typeof(return)(s.get!ulong(0));
        }

        return typeof(return).Invalid;
    }

    /// Ditto
    Index!Task find(TaskKey id)
    {
        import std.conv : to;

        alias s = sqlFindTaskByKey;

        synchronized (s)
        {
            scope (exit) s.reset();

            s.bind(id.commands.to!string, id.workingDirectory);

            if (s.step())
                return typeof(return)(s.get!ulong(0));
        }

        return typeof(return).Invalid;
    }

    /**
     * Returns the vertex state at the given index.
     */
    Resource opIndex(Index!Resource index)
    {
        import std.exception : enforce;

        alias s = sqlResourceByIndex;

        synchronized (s)
        {
            scope (exit) s.reset();
            s.bind(index);
            enforce(s.step(), "Vertex does not exist.");
            return s.parse!Resource();
        }
    }

    /// Ditto
    Task opIndex(Index!Task index)
    {
        import std.exception : enforce;

        alias s = sqlTaskByIndex;

        synchronized (s)
        {
            scope (exit) s.reset();
            s.bind(index);
            enforce(s.step(), "Vertex does not exist.");
            return s.parse!Task();
        }
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

        alias s = sqlResourceByKey;

        synchronized (s)
        {
            scope (exit) s.reset();
            s.bind(path);
            enforce(s.step(), "Vertex does not exist.");
            return s.parse!Resource();
        }
    }

    /// Ditto
    Task opIndex(TaskKey key)
    {
        import std.exception : enforce;
        import std.conv : to;

        alias s = sqlTaskByKey;

        synchronized (s)
        {
            scope (exit) s.reset();
            s.bind(key.commands.to!string, key.workingDirectory);
            enforce(s.step(), "Vertex does not exist.");
            return s.parse!Task();
        }
    }

    /**
     * Changes the state of the vertex at the given index. Throws an exception if
     * the vertex does not exist.
     */
    void opIndexAssign(in Resource v, Index!Resource index)
    {
        alias s = sqlUpdateResource;

        synchronized (s)
        {
            scope (exit) s.reset();
            s.bind(v.path, v.status, v.checksum, index);
            s.step();
        }
    }

    /// Ditto
    void opIndexAssign(in Task v, Index!Task index)
    {
        import std.conv : to;

        alias s = sqlUpdateTask;

        synchronized (s)
        {
            scope (exit) s.reset();
            s.bind(v.commands.to!string,
                   v.workingDirectory,
                   v.display,
                   v.lastExecuted.stdTime, index);
            s.step();
        }
    }

    /**
     * Returns an input range that iterates over all resources. The order is
     * guaranteed to be the same as the order they were inserted in.
     */
    @property auto enumerate(T : Resource)()
    {
        return prepare(
                `SELECT path,status,checksum FROM resource WHERE id>1`
                ).rows!(parse!T);
    }

    unittest
    {
        import std.algorithm : equal;

        auto state = new BuildState;

        immutable vertices = [
            Resource("foo.o", Resource.Status.unknown),
            Resource("foo.c", Resource.Status.file),
            Resource("bar.c", Resource.Status.missing),
            Resource("bar.o", Resource.Status.missing),
            ];

        foreach (vertex; vertices)
            state.put(vertex);

        assert(equal(vertices, state.enumerate!Resource));
    }

    /**
     * Returns an input range that iterates over all tasks. The order is
     * guaranteed to be the same as the order they were inserted in.
     */
    @property auto enumerate(T : Task)()
    {
        return prepare(`SELECT commands,workDir,display,lastExecuted FROM task`)
            .rows!(parse!T);
    }

    unittest
    {
        import std.algorithm : equal, sort;

        auto state = new BuildState;

        immutable tasks = [
            Task([Command(["foo", "arg 1", "arg 2"])]),
            Task([Command(["bar", "arg 1"])]),
            Task([Command(["baz", "arg 1", "arg 2", "arg 3"])]),
            ];

        foreach (task; tasks)
            state.put(task);

        assert(equal(tasks, state.enumerate!Task));
    }

    /**
     * Returns a range of vertex keys. The returned range is not guaranteed to
     * be sorted.
     */
    @property auto enumerate(T : ResourceKey)()
    {
        return prepare(`SELECT path FROM resource WHERE id>1`)
            .rows!(parse!T);
    }

    /// Ditto
    @property auto enumerate(T : TaskKey)()
    {
        return prepare(`SELECT commands,workDir FROM task`)
            .rows!(parse!TaskKey);
    }

    /**
     * Returns a range of row indices.
     */
    @property auto enumerate(T : Index!Resource)()
    {
        return prepare(`SELECT id FROM resource WHERE id>1`)
            .rows!((SQLite3.Statement s) => T(s.get!ulong(0)));
    }

    /// Ditto
    @property auto enumerate(T : Index!Task)()
    {
        return prepare(`SELECT id FROM task`)
            .rows!((SQLite3.Statement s) => T(s.get!ulong(0)));
    }

    /**
     * Adds an edge. Throws an exception if the edge already exists. Returns the
     * index of the edge.
     */
    void put(Index!Task from, Index!Resource to, EdgeType type)
    {
        alias s = sqlInsertTaskEdge;

        synchronized (s)
        {
            scope (exit) s.reset();
            s.bind(from, to, type);
            s.step();
        }
    }

    /// Ditto
    void put(Index!Resource from, Index!Task to, EdgeType type)
    {
        alias s = sqlInsertResourceEdge;

        synchronized (s)
        {
            scope (exit) s.reset();
            s.bind(from, to, type);
            s.step();
        }
    }

    /// Ditto
    void put(ResourceId a, TaskKey b, EdgeType type)
    {
        put(find(a), find(b), type);
    }

    /// Ditto
    void put(TaskKey a, ResourceId b, EdgeType type)
    {
        put(find(a), find(b), type);
    }

    /**
     * Removes an edge. Throws an exception if the edge does not exist.
     */
    void remove(Index!Resource from, Index!Task to, EdgeType type)
    {
        alias s = sqlRemoveResourceEdge;

        synchronized (s)
        {
            scope (exit) s.reset();
            s.bind(from, to, type);
            s.step();
        }
    }

    /// Ditto
    void remove(Index!Task from, Index!Resource to, EdgeType type)
    {
        alias s = sqlRemoveTaskEdge;

        synchronized (s)
        {
            scope (exit) s.reset();
            s.bind(from, to, type);
            s.step();
        }
    }

    /// Ditto
    void remove(TaskKey from, ResourceId to, EdgeType type)
    {
        remove(find(from), find(to), type);
    }

    /// Ditto
    void remove(ResourceId from, TaskKey to, EdgeType type)
    {
        remove(find(from), find(to), type);
    }

    unittest
    {
        auto state = new BuildState;

        immutable resId  = state.put(Resource("foo.c"));
        immutable taskId = state.put(Task([Command(["gcc", "foo.c"])]));
        state.remove(resId);
        state.remove(taskId);
    }

    /**
     * Returns the number of incoming edges to the given vertex.
     */
    size_t degreeIn(Index!Resource index)
    {
        import std.exception : enforce;

        alias s = sqlResourceDegreeIn;

        synchronized (s)
        {
            scope (exit) s.reset();
            s.bind(index);
            enforce(s.step(), "Failed to count incoming edges to resource");
            return s.get!(typeof(return))(0);
        }
    }

    /// Ditto
    size_t degreeIn(Index!Task index)
    {
        import std.exception : enforce;

        alias s = sqlTaskDegreeIn;

        synchronized (s)
        {
            scope (exit) s.reset();
            s.bind(index);
            enforce(s.step(), "Failed to count incoming edges to resource");
            return s.get!(typeof(return))(0);
        }
    }

    /// Ditto
    size_t degreeOut(Index!Resource index)
    {
        import std.exception : enforce;

        alias s = sqlResourceDegreeOut;

        synchronized (s)
        {
            scope (exit) s.reset();
            s.bind(index);
            enforce(s.step(), "Failed to count outgoing edges from resource");
            return s.get!(typeof(return))(0);
        }
    }

    /// Ditto
    size_t degreeOut(Index!Task index)
    {
        import std.exception : enforce;

        alias s = sqlTaskDegreeOut;

        synchronized (s)
        {
            scope (exit) s.reset();
            s.bind(index);
            enforce(s.step(), "Failed to count outgoing edges from task");
            return s.get!(typeof(return))(0);
        }
    }

    unittest
    {
        auto state = new BuildState();

        auto resources = [
            state.put(Resource("foo")),
            state.put(Resource("bar")),
            ];

        auto tasks = [
            state.put(Task([Command(["test"])])),
            state.put(Task([Command(["foobar", "foo", "bar"])])),
            ];

        state.put(tasks[0], resources[0], EdgeType.explicit);
        state.put(tasks[0], resources[1], EdgeType.explicit);

        state.put(resources[0], tasks[1], EdgeType.explicit);
        state.put(resources[1], tasks[1], EdgeType.explicit);

        assert(state.degreeIn(tasks[0])     == 0);
        assert(state.degreeIn(tasks[1])     == 2);
        assert(state.degreeIn(resources[0]) == 1);
        assert(state.degreeIn(resources[1]) == 1);

        assert(state.degreeOut(tasks[0])     == 2);
        assert(state.degreeOut(tasks[1])     == 0);
        assert(state.degreeOut(resources[0]) == 1);
        assert(state.degreeOut(resources[1]) == 1);
    }

    /**
     * Lists all outgoing task edges.
     */
    @property auto edges(From : Task, To : Resource, Data : EdgeType)()
    {
        return prepare(`SELECT "from","to","type" FROM taskEdge`)
            .rows!(parse!(EdgeRow!(From, To, Data)));
    }

    /// Ditto
    @property auto edges(From : Task, To : Resource, Data : EdgeType)
        (EdgeType type)
    {
        return prepare(`SELECT "from","to","type" FROM taskEdge WHERE type=?`,
                type)
            .rows!(parse!(EdgeRow!(From, To, Data)));
    }

    /**
     * Checks if an edge exists between two vertices.
     */
    bool edgeExists(Index!Task from, Index!Resource to, EdgeType type)
    {
        alias s = sqlTaskEdgeExists;

        synchronized (s)
        {
            scope (exit) s.reset();
            s.bind(from, to, type);
            return s.step();
        }
    }

    /// Ditto
    bool edgeExists(Index!Resource from, Index!Task to, EdgeType type)
    {
        alias s = sqlResourceEdgeExists;

        synchronized (s)
        {
            scope (exit) s.reset();
            s.bind(from, to, type);
            return s.step();
        }
    }

    /**
     * Lists all outgoing resource edges.
     */
    @property auto edges(From : Resource, To : Task, Data : EdgeType)()
    {
        return prepare(`SELECT "from","to","type" FROM resourceEdge`)
            .rows!(parse!(EdgeRow!(From, To, Data)));
    }

    /// Ditto
    @property auto edges(From : Resource, To : Task, Data : EdgeType)
        (EdgeType type)
    {
        return prepare(
                `SELECT "from","to","type" FROM resourceEdge WHERE type=?`,
                type)
            .rows!(parse!(EdgeRow!(From, To, Data)));
    }

    /**
     * Returns the outgoing neighbors of the given node.
     */
    @property auto outgoing(Index!Resource v)
    {
        return prepare(`SELECT "to" FROM resourceEdge WHERE "from"=?`, v)
            .rows!((SQLite3.Statement s) => Index!Task(s.get!ulong(0)));
    }

    /// Ditto
    @property auto outgoing(Index!Task v)
    {
        return prepare(`SELECT "to" FROM taskEdge WHERE "from"=?`, v)
            .rows!((SQLite3.Statement s) => Index!Resource(s.get!ulong(0)));
    }

    /// Ditto
    @property auto outgoing(Data : EdgeType)(Index!Resource v)
    {
        return prepare(`SELECT "to",type FROM resourceEdge WHERE "from"=?`, v)
            .rows!(parse!(Neighbor!(Index!Task, Data)));
    }

    /// Ditto
    @property auto outgoing(Data : EdgeType)(Index!Task v)
    {
        return prepare(`SELECT "to",type FROM taskEdge WHERE "from"=?`, v)
            .rows!(parse!(Neighbor!(Index!Resource, Data)));
    }

    /// Ditto
    @property auto outgoing(Data : EdgeIndex!(Resource, Task))(Index!Resource v)
    {
        return prepare(`SELECT "to",id FROM resourceEdge WHERE "from"=?`, v)
            .rows!(parse!(Neighbor!(Index!Task, Data)));
    }

    /// Ditto
    @property auto outgoing(Data : EdgeIndex!(Task, Resource))(Index!Task v)
    {
        return prepare(`SELECT "to",id FROM taskEdge WHERE "from"=?`, v)
            .rows!(parse!(Neighbor!(Index!Resource, Data)));
    }

    /// Ditto
    @property auto outgoing(Data : ResourceId)(Index!Task v)
    {
        return prepare(
                `SELECT resource.path` ~
                ` FROM taskEdge AS e` ~
                ` JOIN resource ON e."to"=resource.id` ~
                ` WHERE e."from"=?`, v
                )
            .rows!((SQLite3.Statement s) => s.get!string(0));
    }

    /// Ditto
    @property auto outgoing(Data : Resource)(Index!Task v, EdgeType type)
    {
        return prepare(
                `SELECT resource.path, resource.status, resource.checksum` ~
                ` FROM taskEdge AS e` ~
                ` JOIN resource ON e."to"=resource.id` ~
                ` WHERE e."from"=? AND type=?`, v, type
                )
            .rows!(parse!Resource);
    }

    /**
     * Returns the incoming neighbors of the given node.
     */
    @property auto incoming(Data : EdgeType)(Index!Resource v)
    {
        return prepare(`SELECT "from",type FROM taskEdge WHERE "to"=?`, v)
            .rows!(parse!(Neighbor!(Index!Task, Data)));
    }

    /// Ditto
    @property auto incoming(Data : EdgeType)(Index!Task v)
    {
        return prepare(`SELECT "from",type FROM resourceEdge WHERE "to"=?`, v)
            .rows!(parse!(Neighbor!(Index!Resource, Data)));
    }

    /// Ditto
    @property auto incoming(Data : EdgeIndex!(Resource, Task))(Index!Resource v)
    {
        return prepare(`SELECT "from",id FROM taskEdge WHERE "to"=?`, v)
            .rows!(parse!(Neighbor!(Index!Task, Data)));
    }

    /// Ditto
    @property auto incoming(Data : EdgeIndex!(Task, Resource))(Index!Task v)
    {
        return prepare(`SELECT "from",id FROM resourceEdge WHERE "to"=?`, v)
            .rows!(parse!(Neighbor!(Index!Resource, Data)));
    }

    /// Ditto
    @property auto incoming(Data : ResourceId)(Index!Task v)
    {
        return prepare(
                `SELECT resource.path` ~
                ` FROM resourceEdge AS e` ~
                ` JOIN resource ON e."from"=resource.id` ~
                ` WHERE e."to"=?`, v
                )
            .rows!((SQLite3.Statement s) => s.get!string(0));
    }

    /// Ditto
    @property auto incoming(Data : Resource)(Index!Task v, EdgeType type)
    {
        return prepare(
                `SELECT resource.path, resource.status, resource.checksum` ~
                ` FROM resourceEdge AS e` ~
                ` JOIN resource ON e."from"=resource.id` ~
                ` WHERE e."to"=? AND type=?`, v, type
                )
            .rows!(parse!Resource);
    }

    /**
     * Adds a vertex to the list of pending vertices. If the vertex is already
     * pending, nothing is done.
     */
    void addPending(Index!Resource v)
    {
        alias s = sqlAddPendingResource;

        synchronized (s)
        {
            scope (exit) s.reset();
            s.bind(v);
            s.step();
        }
    }

    /// Ditto
    void addPending(Index!Task v)
    {
        alias s = sqlAddPendingTask;

        synchronized (s)
        {
            scope (exit) s.reset();
            s.bind(v);
            s.step();
        }
    }

    /**
     * Removes a pending vertex.
     */
    void removePending(Index!Resource v)
    {
        alias s = sqlRemovePendingResource;

        synchronized (s)
        {
            scope (exit) s.reset();
            s.bind(v);
            s.step();
        }
    }

    /// Ditto
    void removePending(Index!Task v)
    {
        alias s = sqlRemovePendingTask;

        synchronized (s)
        {
            scope (exit) s.reset();
            s.bind(v);
            s.step();
        }
    }

    /// Ditto
    void removePending(ResourceId v)
    {
        removePending(find(v));
    }

    /// Ditto
    void removePending(TaskKey v)
    {
        removePending(find(v));
    }

    /**
     * Returns true if a given vertex is pending.
     */
    bool isPending(Index!Resource v)
    {
        import std.exception : enforce;

        alias s = sqlIsPendingResource;

        synchronized (s)
        {
            scope (exit) s.reset();
            s.bind(v);
            enforce(s.step(), "Failed to check if resource is pending");
            return s.get!uint(0) == 1;
        }
    }

    /// Ditto
    bool isPending(Index!Task v)
    {
        import std.exception : enforce;

        alias s = sqlIsPendingTask;

        synchronized (s)
        {
            scope (exit) s.reset();
            s.bind(v);
            enforce(s.step(), "Failed to check if task is pending");
            return s.get!uint(0) == 1;
        }
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

    unittest
    {
        import std.algorithm : map, equal;
        import std.array : array;

        auto state = new BuildState;

        assert(state.pending!Resource.empty);
        assert(state.pending!Task.empty);

        immutable resources = ["a", "b", "c"];
        auto resourceIds = resources.map!(r => state.put(Resource(r))).array;

        immutable tasks = [[Command(["foo"])], [Command(["bar"])]];
        auto taskIds = tasks.map!(t => state.put(Task(t))).array;

        foreach (immutable id; resourceIds)
            state.addPending(id);

        foreach (immutable id; taskIds)
            state.addPending(id);

        assert(equal(state.pending!Resource, resourceIds));
        assert(equal(state.pending!Task, taskIds));

        state.removePending(resourceIds[0]);
        state.removePending(taskIds[1]);

        assert(equal(state.pending!Resource, [3, 4].map!(x => Index!Resource(x))));
        assert(equal(state.pending!Task, [Index!Task(1)]));
    }

    /**
     * Finds vertices with no incoming and no outgoing edges.
     */
    @property auto islands(Vertex : Resource)()
    {
        return prepare(
                `SELECT id FROM resource` ~
                ` WHERE id>1 AND` ~
                ` resource.id`
                ).rows!((SQLite3.Statement s) => Index!Vertex(s.get!string(0)));
    }
}
