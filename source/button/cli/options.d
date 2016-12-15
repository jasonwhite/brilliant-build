/**
 * Copyright: Copyright Jason White, 2016
 * License:   MIT
 * Authors:   Jason White
 *
 * Description:
 * All command line interface options.
 */
module button.cli.options;

import std.meta : AliasSeq;

import darg;

import button.exceptions;

struct Command
{
    string name;
}

struct Description
{
    string description;
}

struct GlobalOptions
{
    @Option("help")
    @Help("Prints help on command line usage.")
    OptionFlag help;

    @Option("version")
    @Help("Prints version information.")
    OptionFlag version_;

    @Argument("command", Multiplicity.optional)
    string command;

    @Argument("args", Multiplicity.zeroOrMore)
    const(string)[] args;
}

// Generate usage and help strings at compile-time.
immutable globalUsage = usageString!GlobalOptions("button");
immutable globalHelp  = helpString!GlobalOptions();

@Command("help")
@Description("Displays help on a given command.")
struct HelpOptions
{
    @Argument("command", Multiplicity.optional)
    @Help("Command to get help on.")
    string command;
}

@Command("version")
@Description("Prints the current version of the program.")
struct VersionOptions
{
}

@Command("build")
@Description("Runs a build.")
struct BuildOptions
{
    @Option("file", "f")
    @Help("Path to the build description.")
    string path;

    @Option("dryrun", "n")
    @Help("Don't make any functional changes. Just print what might happen.")
    OptionFlag dryRun;

    @Option("threads", "j")
    @Help("The number of threads to use. Default is the number of logical
            cores.")
    @MetaVar("N")
    size_t threads;

    @Option("color")
    @Help("When to colorize the output.")
    @MetaVar("{auto,never,always}")
    string color = "auto";

    @Option("verbose", "v")
    @Help("Display additional information such as how long each task took to"~
          " complete.")
    OptionFlag verbose;

    @Option("autopilot")
    @Help("After building, continue watching for changes to inputs and"~
          " building again as necessary.")
    OptionFlag autopilot;

    @Option("watchdir")
    @Help("Used with `--autopilot`. Directory to watch for changes in. Since"~
          " FUSE does not work with inotify, this is useful to use when"~
          " building in a union file system.")
    string watchDir = ".";

    @Option("delay")
    @Help("Used with `--autopilot`. The number of milliseconds to wait for"~
          " additional changes after receiving a change event before starting"~
          " a build.")
    size_t delay = 50;
}

@Command("graph")
@Description("Generates a graph for input into GraphViz.")
struct GraphOptions
{
    import button.edgedata : EdgeType;

    @Option("file", "f")
    @Help("Path to the build description.")
    string path;

    @Option("changes", "C")
    @Help("Only display the subgraph that will be traversed on an update.")
    OptionFlag changes;

    @Option("cached")
    @Help("Display the cached graph from the previous build.")
    OptionFlag cached;

    @Option("full")
    @Help("Display the full name of each vertex.")
    OptionFlag full;

    @Option("edges", "e")
    @MetaVar("{explicit,implicit,both}")
    @Help("Type of edges to show.")
    EdgeType edges = EdgeType.explicit;

    @Option("threads", "j")
    @Help("The number of threads to use. Default is the number of logical
            cores.")
    @MetaVar("N")
    size_t threads;
}

@Command("status")
@Description("Prints the status of the build. That is, which files have been
        modified and which tasks are pending.")
struct StatusOptions
{
    @Option("file", "f")
    @Help("Path to the build description.")
    string path;

    @Option("cached")
    @Help("Display the cached graph from the previous build.")
    OptionFlag cached;

    @Option("color")
    @Help("When to colorize the output.")
    @MetaVar("{auto,never,always}")
    string color = "auto";

    @Option("threads", "j")
    @Help("The number of threads to use. Default is the number of logical
            cores.")
    @MetaVar("N")
    size_t threads;
}

@Command("clean")
@Description("Deletes all build outputs.")
struct CleanOptions
{
    @Option("file", "f")
    @Help("Path to the build description.")
    string path;

    @Option("dryrun", "n")
    @Help("Don't make any functional changes. Just print what might happen.")
    OptionFlag dryRun;

    @Option("threads", "j")
    @Help("The number of threads to use. Default is the number of logical
            cores.")
    @MetaVar("N")
    size_t threads;

    @Option("color")
    @Help("When to colorize the output.")
    @MetaVar("{auto,never,always}")
    string color = "auto";

    @Option("purge")
    @Help("Delete the build state too.")
    OptionFlag purge;
}

@Command("init")
@Description("Initializes a directory with an initial build description.")
struct InitOptions
{
    @Argument("dir", Multiplicity.optional)
    @Help("Directory to initialize")
    string dir = ".";
}

enum ConvertFormat
{
    bash,
}

@Command("convert")
@Description("Converts the build description to another format for other build systems.")
struct ConvertOptions
{
    @Option("file", "f")
    @Help("Path to the build description.")
    string path;

    @Option("format")
    @Help("Format of build description to convert to. Default is 'bash'.")
    @MetaVar("{bash}")
    ConvertFormat type;

    @Argument("output")
    @Help("Path to the output file.")
    @MetaVar("FILE")
    string output;
}

@Command("gc")
@Description("EXPERIMENTAL")
struct GCOptions
{
    @Option("file", "f")
    @Help("Path to the build description.")
    string path;

    @Option("dryrun", "n")
    @Help("Don't make any functional changes. Just print what might happen.")
    OptionFlag dryRun;

    @Option("color")
    @Help("When to colorize the output.")
    @MetaVar("{auto,never,always}")
    string color = "auto";
}

/**
 * List of all options structs.
 */
alias OptionsList = AliasSeq!(
        HelpOptions,
        VersionOptions,
        BuildOptions,
        GraphOptions,
        StatusOptions,
        CleanOptions,
        InitOptions,
        GCOptions,
        ConvertOptions,
        );

/**
 * Using the list of command functions, runs a command from the specified
 * string.
 *
 * Throws: InvalidCommand if the given command name is not valid.
 */
int runCommand(Funcs...)(string name, GlobalOptions opts)
{
    import std.traits : Parameters, getUDAs;
    import std.format : format;

    foreach (F; Funcs)
    {
        alias Options = Parameters!F[0];

        alias Commands = getUDAs!(Options, Command);

        foreach (C; Commands)
        {
            if (C.name == name)
                return F(parseArgs!Options(opts.args), opts);
        }
    }

    throw new InvalidCommand("button: '%s' is not a valid command. See 'button help'."
            .format(name));
}
