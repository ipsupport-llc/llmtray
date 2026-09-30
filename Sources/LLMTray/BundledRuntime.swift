#if APP_STORE
import Foundation

/// The App Store build's one Python runtime (adr/0018): the python.org
/// framework and a single packages folder, both inside the signed bundle,
/// for the server, the embedder, voice and music alike (they share one set
/// of packages without conflict: our mlx-lm fork, mlx-audio, their extras).
/// Nothing is installed or updated after install -- guideline 2.5.2 -- and
/// no venv: the packages go on PYTHONPATH, set once at launch so every
/// runner the app starts inherits it. The standalone build never compiles
/// this; it keeps its venvs.
enum BundledRuntime {
    private static var frameworkVersions: String {
        (Bundle.main.privateFrameworksPath ?? "") + "/Python.framework/Versions"
    }

    /// Contents/Frameworks/Python.framework/Versions/3.X/bin/python3.X.
    static var python: String {
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: frameworkVersions)) ?? []
        for version in versions.sorted() where version != "Current" {
            let candidate = "\(frameworkVersions)/\(version)/bin/python\(version)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return frameworkVersions + "/Current/bin/python3"
    }

    /// Contents/Resources/python-packages: what `pip install --target` put
    /// there at build time (scripts/build_appstore.sh).
    static var packages: String { (Bundle.main.resourcePath ?? "") + "/python-packages" }

    /// Every package's folder is here (not under a venv's lib/pythonX/).
    static var sitePackageDirs: [String] { [packages] }

    /// Called first thing at launch. HOME is the app's container (the
    /// sandbox's), so Hugging Face's cache and every runner's scratch space
    /// land in it.
    static func configureEnvironment() {
        setenv("PYTHONPATH", packages, 1)
        setenv("PYTHONNOUSERSITE", "1", 1)
        // The bundle is read-only (and sealed): no __pycache__ in it.
        setenv("PYTHONDONTWRITEBYTECODE", "1", 1)
        setenv("HOME", NSHomeDirectory(), 1)
        setenv("TMPDIR", NSTemporaryDirectory(), 1)
        // Every runner exits when the app does, crashed or force-quit too
        // (python-packages/sitecustomize.py): the sandbox lets the app see
        // a leftover runner but not signal it.
        setenv("LLMTRAY_EXIT_WITH_PARENT", "1", 1)
    }
}
#endif
