function run(argv) {
    if (argv.length !== 2) return "syntax-ok";
    const inputPath = argv[0];
    const outputPath = argv[1];
    const pages = Application("Pages");
    pages.includeStandardAdditions = true;
    pages.activate();
    let document = null;
    try {
        document = pages.open(Path(inputPath));
        document.export({ to: Path(outputPath), as: "PDF" });
        document.close({ saving: "no" });
    } catch (error) {
        if (document) {
            try { document.close({ saving: "no" }); } catch (_) {}
        }
        throw error;
    }
    return outputPath;
}
