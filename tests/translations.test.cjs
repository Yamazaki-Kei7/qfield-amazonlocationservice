const { test } = require("node:test")
const assert = require("node:assert/strict")
const { readdirSync, readFileSync } = require("node:fs")
const { join } = require("node:path")

const root = join(__dirname, "..")
const read = name => readFileSync(join(root, name), "utf8")
const entities = { apos: "'", quot: '"', lt: "<", gt: ">", amp: "&" }
const unescape = text => text.replace(/&(apos|quot|lt|gt|amp);/g, (entity, name) => entities[name])
const placeholders = text => Array.from(new Set(text.match(/%\d+/g))).sort()

// Every catalog shipped with the plugin is checked, so a new language needs no change here.
const catalogs = readdirSync(root).filter(name => /^main_.+\.ts$/.test(name))
const messages = name => Array.from(read(name).matchAll(/<message>([\s\S]*?)<\/message>/g), ([, message]) => ({
    source: unescape(message.match(/<source>([\s\S]*?)<\/source>/)[1]),
    finished: !/<translation[^>]*type=/.test(message),
    translation: unescape(message.match(/<translation[^>]*>([\s\S]*?)<\/translation>/)[1])
}))

// The source strings lupdate extracts, read from the same calls.
const displayed = Array.from(new Set(readdirSync(root).filter(name => /\.(qml|js)$/.test(name)).flatMap(name =>
    Array.from(read(name).matchAll(/qsTranslate\("AmazonLocationService", "((?:[^"\\]|\\.)*)"/g), match => JSON.parse('"' + match[1] + '"'))
))).sort()

test("the plugin ships at least one translation catalog", () => {
    assert.ok(catalogs.length > 0)
    assert.ok(displayed.length > 0)
})

for (const name of catalogs) {
    test(name + " translates every string and keeps its placeholders", () => {
        for (const message of messages(name)) {
            assert.ok(message.finished && message.translation.trim(), "untranslated: " + message.source)
            assert.deepEqual(placeholders(message.translation), placeholders(message.source), "placeholders differ: " + message.source)
        }
    })

    test(name + " lists exactly the strings the plugin displays", () => {
        assert.deepEqual(Array.from(new Set(messages(name).map(message => message.source))).sort(), displayed)
    })
}
