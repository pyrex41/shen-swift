import Foundation
import ShenSwift

// The tree-walking evaluator recurses on the host stack for non-tail calls
// (e.g. the recursive arm of `append`). Run everything on a dedicated thread
// with a large stack so deep user recursion does not overflow.
/// Reports a fatal error on stderr and exits.
///
/// stderr is unbuffered while stdout, when it is a pipe, is fully buffered, so
/// anything the interpreter has already printed must be flushed first — otherwise
/// the diagnostic overtakes it in a merged (`2>&1`) capture.
func die(_ message: String) -> Never {
    fflush(stdout)
    FileHandle.standardError.write(Data((message + "\n").utf8))
    Foundation.exit(1)
}

final class Runner: Thread {
    let args: [String]
    init(args: [String]) { self.args = args; super.init() }

    override func main() {
        let verbose = args.contains("--verbose") || args.contains("-v")
        let interp = Interp()

        // Strip ShenSwift-internal flags; everything else is forwarded verbatim
        // to the kernel launcher (eval / script / repl / --version / --help).
        // `--shaken <kernel.kl> <user.kl>` switches to Yggdrasil stage-2 mode:
        // boot a minimal shaken slice (kernel + user) and run the user program
        // to completion instead of loading the full kernel + launcher.
        var launcherArgs: [String] = ["shen-swift"]
        var shakenKernel: URL? = nil
        var shakenUser: URL? = nil
        var stdlib = false
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--verbose", "-v":
                i += 1
            case "--stdlib":
                stdlib = true
                i += 1
            case "--kl":
                if i + 1 < args.count { interp.klDirectory = URL(fileURLWithPath: args[i + 1]) }
                i += 2
            case "--shaken":
                if i + 2 < args.count {
                    shakenKernel = URL(fileURLWithPath: args[i + 1])
                    shakenUser = URL(fileURLWithPath: args[i + 2])
                }
                i += 3
            default:
                launcherArgs.append(args[i]); i += 1
            }
        }

        // Yggdrasil stage-2 path: shaken-slice boot, no kernel launcher.
        if let kern = shakenKernel, let usr = shakenUser {
            do {
                try interp.bootShaken(kernel: kern, user: usr, verbose: verbose)
            } catch let e as KLError {
                die("error: \(e.message)")
            } catch {
                die("error: \(error)")
            }
            fflush(stdout)
            Foundation.exit(0)
        }

        do {
            let start = Date()
            try interp.boot(verbose: verbose, stdlib: stdlib)
            if verbose {
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                FileHandle.standardError.write(Data("kernel booted in \(ms) ms\n".utf8))
            }
        } catch let e as KLError {
            die("boot error: \(e.message)")
        } catch {
            die("boot error: \(error)")
        }

        do {
            try interp.runLauncher(launcherArgs)
        } catch let e as KLError {
            die("error: \(e.message)")
        } catch {
            die("error: \(error)")
        }
        fflush(stdout)
        Foundation.exit(0)
    }
}

let runner = Runner(args: Array(CommandLine.arguments.dropFirst()))
runner.stackSize = 512 * 1024 * 1024 // 512 MB
runner.start()

// Keep the main thread alive while the runner works.
while !runner.isFinished {
    Thread.sleep(forTimeInterval: 0.05)
}
