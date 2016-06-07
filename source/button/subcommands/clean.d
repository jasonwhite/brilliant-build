/**
 * Copyright: Copyright Jason White, 2016
 * License:   MIT
 * Authors:   Jason White
 *
 * Description:
 * Command to delete outputs.
 */
module button.subcommands.clean;

import button.subcommands.parsing;

import io.text, io.file.stdio;

import button.state,
       button.rule,
       button.graph,
       button.build,
       button.textcolor;

/**
 * Deletes outputs.
 */
int cleanCommand(CleanOptions opts, GlobalOptions globalOpts)
{
    import std.getopt;
    import std.file : remove;

    immutable color = TextColor(colorOutput(opts.color));

    try
    {
        string path = buildDescriptionPath(opts.path);
        string statePath = path.stateName;

        auto state = new BuildState(statePath);

        {
            state.begin();
            scope (success)
            {
                if (opts.dryRun)
                    state.rollback();
                else
                    state.commit();
            }

            scope (failure)
                state.rollback();

            clean(state, opts.dryRun);
        }

        // Close the database before deleting it.
        state.close();

        if (opts.purge)
        {
            println("Deleting `", statePath, "`");
            remove(statePath);
        }
    }
    catch (BuildException e)
    {
        stderr.println(color.status, ":: ", color.error,
                "Error", color.reset, ": ", e.msg);
        return 1;
    }

    return 0;
}