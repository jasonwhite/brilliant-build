/**
 * Copyright: Copyright Jason White, 2015
 * License:   $(WEB boost.org/LICENSE_1_0.txt, Boost License 1.0).
 * Authors:   Jason White
 *
 * Description:
 * Parses rules.
 */
import io;
import bb.rule;
import bb.taskgraph;

int main(string[] args)
{
    import std.json : JSONException;

    try
    {
        TaskGraph graph;
        graph.addRules(stdin.parseRules());
        graph.display(stdout);
    }
    catch (JSONException e)
    {
        stderr.println("Error parsing rules from JSON (", e.msg, ")");
        return 1;
    }

    return 0;
}