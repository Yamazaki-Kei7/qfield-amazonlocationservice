const { readFileSync } = require("node:fs")
const { join } = require("node:path")
const { createContext, runInContext } = require("node:vm")

// Supply the Qt translation globals that Routes.js uses when running inside QField.
module.exports = function loadRoutes() {
    const context = createContext({ qsTranslate: (_context, source) => source })
    const strings = runInContext("String.prototype", context)
    strings.arg = function(value) {
        const indexes = Array.from(this.matchAll(/%(\d+)/g), match => Number(match[1]))
        const next = Math.min(...indexes)
        return this.replace(/%(\d+)/g, (token, index) => Number(index) === next ? String(value) : token)
    }
    runInContext(readFileSync(join(__dirname, "../Routes.js"), "utf8"), context)
    return context
}
