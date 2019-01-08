module redbat.cosmetic;

import xcb.xcb;

class CosmeticFactory
{
    import redbat.window;

    Window root;

    this(Window root)
    {
        this.root = root;
    }

    xcb_gcontext_t createGCWithFG(in string fgColorName)
    {
        auto gc = xcb_generate_id(root.connection);

        uint[] valuesGC = [getPixByColorName(fgColorName), 0];
        xcb_create_gc(root.connection, gc, root.window, XCB_GC_FOREGROUND | XCB_GC_GRAPHICS_EXPOSURES, valuesGC.ptr);
        return gc;
    }

    xcb_gcontext_t createGCWithBG(in string bgColorName)
    {
        auto gc = xcb_generate_id(root.connection);

        uint[] valuesGC = [getPixByColorName(bgColorName), 0];
        xcb_create_gc(root.connection, gc, root.window, XCB_GC_BACKGROUND | XCB_GC_GRAPHICS_EXPOSURES, valuesGC.ptr);
        return gc;
    }

    xcb_gcontext_t createGCWithFGBG(in string fgColorName, in string bgColorName)
    {
        auto gc = xcb_generate_id(root.connection);

        uint[] valuesGC = [getPixByColorName(fgColorName), getPixByColorName(bgColorName), 0];
        xcb_create_gc(root.connection, gc, root.window, XCB_GC_FOREGROUND | XCB_GC_BACKGROUND | XCB_GC_GRAPHICS_EXPOSURES, valuesGC.ptr);
        return gc;
    }

    uint getPixByColorName(in string colorName)
    {
        auto reply = xcb_alloc_named_color_reply(root.connection, xcb_alloc_named_color(root.connection,
                root.screen.default_colormap, cast(ushort) colorName.length, colorName.ptr), null);
        if (reply is null)
        {
            return root.screen.black_pixel;
        }
        immutable ret = reply.pixel;
        import core.stdc.stdlib : free;

        free(reply);
        return ret;
    }
}
