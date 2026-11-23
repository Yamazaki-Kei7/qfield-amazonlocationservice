.pragma library

const ink = "#232f3e"
const orange = "#ff9900"
const serviceRed = "#dd344c"
const capsuleSurface = "#35485d"
const capsuleBorder = "#8192a3"
const blue = "#005ea8"
const primary = { background: orange, foreground: ink }

const light = {
    canvas: "#f3f5f7",
    surface: "#ffffff",
    selected: { background: blue, foreground: "#ffffff" },
    secondary: { background: "#e9eff5", foreground: "#254760" },
    danger: { background: "#fff1f0", foreground: "#a61d24" }
}

const dark = {
    canvas: "#161d26",
    surface: "#222d3a",
    selected: { background: "#82c8ff", foreground: ink },
    secondary: { background: "#304052", foreground: "#deebf5" },
    danger: { background: "#442c32", foreground: "#ffb4ae" }
}

function forTheme(darkMode) {
    return darkMode ? dark : light
}
