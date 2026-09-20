#!/bin/sh
# UI module -- the only place that knows how output reaches the user.
#
# Recovery reads a pipe on $OUTFD and only renders lines prefixed with
# "ui_print"; kernel flasher apps collect stdout and filter for the same
# prefix. Writing to both is what makes one package work in either.

ui_print() {
    while [ $# -gt 0 ]; do
        if [ -n "$OUTFD" ] && [ -e "/proc/self/fd/$OUTFD" ]; then
            printf "ui_print %s\nui_print\n" "$1" >> "/proc/self/fd/$OUTFD" 2>/dev/null ||
                printf "ui_print %s\n" "$1"
        else
            printf "ui_print %s\n" "$1"
        fi
        shift
    done
}

ui_msg()     { ui_print "==> $1"; }
ui_warn()    { ui_print "!! [WARN] $1"; }
ui_error()   { ui_print "XX [ERROR] $1"; }
ui_success() { ui_print " [OK] $1"; }

ui_abort() {
    ui_error "$1"
    ui_print " "
    ui_print "Installation aborted."
    # Defined by the engine; present even when this module is not.
    type sb_cleanup >/dev/null 2>&1 && sb_cleanup
    exit 1
}

# Banner art and hardware blurb are data, not code: see banner.txt.
show_banner() {
    [ -f banner.txt ] || return 0
    ui_print " "
    while IFS= read -r _line; do ui_print "$_line"; done < banner.txt
    [ -f version ] && ui_print "  Release : $(head -n1 version 2>/dev/null)"
    ui_print "------------------------------------------------------------"
    ui_print " "
}

export UI_LOADED=1
