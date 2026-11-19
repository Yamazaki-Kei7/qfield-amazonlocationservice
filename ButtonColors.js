.pragma library

const ink = "#232f3e"
const orange = "#ff9900"
const blue = "#005ea8"
const primary = { background: orange, foreground: ink }

const light = {
    selected: { background: blue, foreground: "#ffffff" },
    secondary: { background: "#e9eff5", foreground: "#254760" },
    danger: { background: "#fff1f0", foreground: "#a61d24" }
}

const dark = {
    selected: { background: "#82c8ff", foreground: ink },
    secondary: { background: "#304052", foreground: "#deebf5" },
    danger: { background: "#442c32", foreground: "#ffb4ae" }
}

function forTheme(darkMode) {
    return darkMode ? dark : light
}
