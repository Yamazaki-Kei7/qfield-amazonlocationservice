.pragma library

const red = "#b52745"

function foreground(dark) {
    return dark ? "#ffadbc" : red
}

function surface(dark) {
    return dark ? "#48242e" : "#fce8ec"
}
