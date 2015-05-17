/**
 * Copyright: Copyright Jason White, 2015
 * License:   MIT
 * Authors:   Jason White
 *
 * Description:
 * Finds differences between two ranges.
 *
 * All changes are discovered in O(max(n, m)) where n and m are the length of
 * the two ranges.
 */
module bb.change;

import std.range : isForwardRange;

/**
 * Type of a change.
 */
enum ChangeType
{
    none,
    added,
    removed
}

/**
 * Describes a change.
 */
struct Change(T)
{
    T value;
    ChangeType type;
}

/**
 * Range for iterating over changes between two sorted ranges.
 */
struct Changes(R, alias pred = "a < b")
    if (isForwardRange!R)
{
    import std.range : ElementType;
    import std.traits : Unqual;

    alias T = Unqual!(ElementType!R);

    private
    {
        // Current change.
        Change!T current;

        // Next and previous states.
        R prev, next;

        bool _empty;
    }

    this(R prev, R next)
    {
        this.prev = prev;
        this.next = next;

        popFront();
    }

    void popFront()
    {
        import std.range : empty, front, popFront;
        import std.functional : binaryFun;

        if (prev.empty && next.empty)
        {
            _empty = true;
        }
        else if (prev.empty)
        {
            current = Change!T(next.front, ChangeType.added);
            next.popFront();
        }
        else if (next.empty)
        {
            current = Change!T(prev.front, ChangeType.removed);
            prev.popFront();
        }
        else
        {
            immutable a = prev.front;
            immutable b = next.front;

            if (binaryFun!pred(a, b))
            {
                // Removed
                current = Change!T(a, ChangeType.removed);
                prev.popFront();
            }
            else if (binaryFun!pred(b, a))
            {
                // Added
                current = Change!T(b, ChangeType.added);
                next.popFront();
            }
            else
            {
                // No change
                current = Change!T(a, ChangeType.none);
                prev.popFront();
                next.popFront();
            }
        }
    }

    ref const(Change!T) front() const pure nothrow
    {
        return current;
    }

    bool empty() const pure nothrow
    {
        return _empty;
    }
}

/**
 * Convenience function for constructing a range that finds changes between two
 * ranges.
 */
auto changes(alias pred = "a < b", R)(R previous, R next)
{
    return Changes!(R, pred)(previous, next);
}

unittest
{
    import std.algorithm : equal;

    immutable prev = "abcd";
    immutable next = "acdef";

    immutable Change!dchar[] result = [
            {'a', ChangeType.none},
            {'b', ChangeType.removed},
            {'c', ChangeType.none},
            {'d', ChangeType.none},
            {'e', ChangeType.added},
            {'f', ChangeType.added},
        ];

    assert(result.equal(changes(prev, next)));
}
