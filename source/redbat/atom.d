module redbat.atom;

import core.stdc.stdlib : free;
import xcb.xcb;

xcb_atom_t getAtomByName(xcb_connection_t* connection, in string name)
{
    xcb_atom_t ret = XCB_ATOM_NONE;
    auto reply = xcb_intern_atom_reply(connection, xcb_intern_atom(connection, 0, cast(ushort) name.length, name.ptr), null);
    if (reply !is null)
    {
        ret = reply.atom;
        import core.stdc.stdlib : free;

        free(reply);
    }
    return ret;
}

string getAtomName(xcb_connection_t* connection, xcb_atom_t atom)
{
    auto reply = xcb_get_atom_name_reply(connection, xcb_get_atom_name(connection, atom), null);
    if (reply is null)
    {
        return "";
    }
    auto ret = xcb_get_atom_name_name(reply)[0 .. reply.name_len].idup;
    import core.stdc.stdlib : free;

    free(reply);
    return ret;
}
