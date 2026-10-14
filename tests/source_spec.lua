-- tests/source_spec.lua
package.path = "Scripts/?.lua;tests/?.lua;" .. package.path
local H = require("harness")
local S = require("source")

-- UE4SS from commit 3a4b6422 on fills each out-param's own table; older builds
-- put every key in the first. The diag summary must name every field either way.
H.eq("out tables: one key per table",
    S.summariseOutTables({ { OutArrested = 0 }, { OutKilled = 5 }, { OutReported = 0 }, { OutTotal = 18 } }),
    "OutArrested=0, OutKilled=5, OutReported=0, OutTotal=18")
H.eq("out tables: all keys in the first",
    S.summariseOutTables({ { OutArrested = 0, OutKilled = 5 }, {} }),
    "OutArrested=0, OutKilled=5")
H.eq("out tables: all empty", S.summariseOutTables({ {}, {} }), nil)
H.eq("out tables: non-table entry skipped", S.summariseOutTables({ 7, { EvidenceCollected = 2 } }),
    "EvidenceCollected=2")

H.report()
