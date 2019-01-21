module redbat.geometry;
import xcb.xcb;

///
struct Geometry
{
    short x;
    short y;
    ushort width;
    ushort height;
    ushort borderWidth;
}

Geometry getGeometry(xcb_connection_t* connection, xcb_drawable_t drawable)
{
    Geometry geo;
    auto geo_p = xcb_get_geometry_reply(connection, xcb_get_geometry(connection, drawable), null);
    if (geo_p !is null)
    {
        geo.x = geo_p.x;
        geo.y = geo_p.y;
        geo.width = geo_p.width;
        geo.height = geo_p.height;
        geo.borderWidth = geo_p.border_width;
        import core.stdc.stdlib : free;

        free(geo_p);
    }
    return geo;
}

short innerX(Geometry geo)
{
    return cast(short)(geo.x + geo.borderWidth);
}

short innerY(Geometry geo)
{
    return cast(short)(geo.y + geo.borderWidth);
}

ushort outerWidth(Geometry geo)
{
    return cast(ushort)(geo.width + geo.borderWidth * 2);
}

ushort outerHeight(Geometry geo)
{
    return cast(ushort)(geo.height + geo.borderWidth * 2);
}
