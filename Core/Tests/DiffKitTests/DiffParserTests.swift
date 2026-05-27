import Testing
import DiffKit

private let modifiedDiff = """
diff --git a/foo.txt b/foo.txt
index 1111111..2222222 100644
--- a/foo.txt
+++ b/foo.txt
@@ -1,3 +1,3 @@
 alpha
-beta
+BETA
 gamma
"""

private let addedDiff = """
diff --git a/new.txt b/new.txt
new file mode 100644
index 0000000..3333333
--- /dev/null
+++ b/new.txt
@@ -0,0 +1,2 @@
+one
+two
"""

private let deletedDiff = """
diff --git a/gone.txt b/gone.txt
deleted file mode 100644
index 4444444..0000000
--- a/gone.txt
+++ /dev/null
@@ -1 +0,0 @@
-bye
"""

@Test func parsesModifiedFileWithLineNumbers() {
    let files = DiffParser.parse(modifiedDiff)
    #expect(files.count == 1)
    let file = files[0]
    #expect(file.oldPath == "foo.txt")
    #expect(file.newPath == "foo.txt")
    #expect(file.changeKind == .modified)
    #expect(file.addedCount == 1)
    #expect(file.removedCount == 1)
    #expect(file.hunks.count == 1)

    let lines = file.hunks[0].lines
    #expect(lines.count == 4)
    #expect(lines[0].kind == .context)
    #expect(lines[0].text == "alpha")
    #expect(lines[0].oldNumber == 1)
    #expect(lines[0].newNumber == 1)
    #expect(lines[1].kind == .removed)
    #expect(lines[1].text == "beta")
    #expect(lines[1].oldNumber == 2)
    #expect(lines[1].newNumber == nil)
    #expect(lines[2].kind == .added)
    #expect(lines[2].text == "BETA")
    #expect(lines[2].oldNumber == nil)
    #expect(lines[2].newNumber == 2)
    #expect(lines[3].kind == .context)
    #expect(lines[3].oldNumber == 3)
    #expect(lines[3].newNumber == 3)
}

@Test func parsesAddedFile() {
    let files = DiffParser.parse(addedDiff)
    #expect(files.count == 1)
    #expect(files[0].oldPath == nil)
    #expect(files[0].newPath == "new.txt")
    #expect(files[0].changeKind == .added)
    #expect(files[0].addedCount == 2)
    #expect(files[0].removedCount == 0)
    #expect(files[0].hunks[0].lines.map(\.text) == ["one", "two"])
}

@Test func parsesDeletedFile() {
    let files = DiffParser.parse(deletedDiff)
    #expect(files.count == 1)
    #expect(files[0].oldPath == "gone.txt")
    #expect(files[0].newPath == nil)
    #expect(files[0].changeKind == .deleted)
    #expect(files[0].removedCount == 1)
    #expect(files[0].hunks[0].lines[0].kind == .removed)
    #expect(files[0].hunks[0].lines[0].oldNumber == 1)
}

@Test func parsesMultipleFiles() {
    let files = DiffParser.parse(modifiedDiff + "\n" + addedDiff)
    #expect(files.count == 2)
    #expect(files[0].newPath == "foo.txt")
    #expect(files[1].newPath == "new.txt")
}

@Test func emptyDiffYieldsNoFiles() {
    #expect(DiffParser.parse("").isEmpty)
}

private let methodContextDiff = """
diff --git a/m.m b/m.m
index 1111111..2222222 100644
--- a/m.m
+++ b/m.m
@@ -5,3 +5,3 @@ + (void)doThing {
 a
-b
+B
 c
"""

private let multiHunkDiff = """
diff --git a/big.txt b/big.txt
index 1111111..2222222 100644
--- a/big.txt
+++ b/big.txt
@@ -1,2 +1,2 @@
 one
-two
+TWO
@@ -10,2 +10,2 @@
 ten
-eleven
+ELEVEN
"""

@Test func hunkContextWithPlusTokenDoesNotCorruptLineNumbers() {
    let files = DiffParser.parse(methodContextDiff)
    let lines = files[0].hunks[0].lines
    #expect(lines[0].oldNumber == 5)
    #expect(lines[0].newNumber == 5)
    #expect(lines[2].kind == .added)
    #expect(lines[2].newNumber == 6)
}

@Test func parsesMultipleHunksWithIndependentLineNumbers() {
    let files = DiffParser.parse(multiHunkDiff)
    #expect(files.count == 1)
    #expect(files[0].hunks.count == 2)
    #expect(files[0].hunks[1].lines[0].oldNumber == 10)
    #expect(files[0].hunks[1].lines[0].newNumber == 10)
    #expect(files[0].addedCount == 2)
    #expect(files[0].removedCount == 2)
}
