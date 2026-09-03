import Foundation
import OmApi

let usage = """
omgui-cli — command-line front end for omgui-mac (Axivity AX3/AX6)

Usage:
  omgui-cli status   [--long] [--device ID]... [--mock]
  omgui-cli identify [--led N] [--device ID]... [--mock]
  omgui-cli record   --session N [--rate HZ] [--range G] [--gyro DPS] [--low-power]
                     [--immediate | --start "YYYY-MM-DD HH:MM:SS" --stop "YYYY-MM-DD HH:MM:SS"]
                     [--flash] [--yes] [--device ID]... [--mock] [key=value]...
  omgui-cli download --workspace DIR [--template T] [--overwrite] [--force] [--quiet]
                     [--device ID]... [--mock]
  omgui-cli clear    (--device ID... | --all) [--quick] [--yes] [--force] [--mock]

Options:
  --mock            Use the built-in fake devices instead of real hardware
                    (same as OMGUI_MOCK=1; --mock-root DIR moves the fake volumes).
  --device ID       Act on this device only; repeat for several. Default: every attached device.
  --all             clear only: act on every attached device (there is no implicit default,
                    because clear erases the recording).
  --yes             Answer the flows' questions with "yes": clear's confirmation, and the
                    firmware-blacklist / firmware-not-yet-read questions record and clear ask.
  --force           clear: also erase devices that are recording and already hold data, which
                    OMGUI's Clear button refuses. download: write the file even when its name
                    cannot be verified against the device's own data file.
  --rate HZ         3200 1600 800 400 200 100 50 25 12.5 6.25   (default 100)
  --range G         2 4 8 16                                    (default 8)
  --gyro DPS        0 125 250 500 1000 2000  (AX6 only; ignored on an AX3)
  --template T      Download filename template, default "{DeviceId}_{SessionId}".
                    Placeholders: {DeviceId} {SessionId} {StudyCode} {SubjectCode} and the other
                    Study*/Subject* metadata names.
  key=value         Recording metadata. Keys may be OMGUI's short form (_sc) or the display name
                    (SubjectCode): StudyCentre StudyCode StudyInvestigator StudyExerciseType
                    StudyOperator StudyNotes SubjectSite SubjectCode SubjectSex SubjectHeight
                    SubjectWeight SubjectHandedness SubjectNotes.

Exit codes: 0 success, 1 usage error, 2 no devices found, 3 operation failed.
"""

/// On the main actor because the commands are: they run the same `OmGuiCore` flows the app does,
/// and those are `@MainActor` for the sake of the message boxes they put up. Top-level code is on
/// the main actor already, so `exit(run())` below needs nothing else.
@MainActor
func run() -> Int32 {
    setvbuf(stdout, nil, _IOLBF, 0)   // keep progress output interleaved correctly when piped
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.isEmpty || arguments.contains("--help") || arguments.contains("-h") {
        print(usage)
        return arguments.isEmpty ? 1 : 0
    }

    let options: Options
    do {
        options = try Options.parse(arguments)
    } catch let error as CLIError {
        FileHandle.standardError.write(Data("ERROR \(error.description)\n\n".utf8))
        print(usage)
        return error.exitCode
    } catch {
        FileHandle.standardError.write(Data("ERROR \(error)\n".utf8))
        return 1
    }

    let runner = Runner(options: options)
    defer { runner.stop() }

    do {
        try runner.start()
        switch options.command {
        case "status": try Commands.status(runner)
        case "identify": try Commands.identify(runner)
        case "record": try Commands.record(runner)
        case "download": try Commands.download(runner)
        case "clear": try Commands.clear(runner)
        default: throw CLIError.usage("Unknown command \"\(options.command)\"")
        }
        return 0
    } catch let error as CLIError {
        FileHandle.standardError.write(Data("ERROR \(error.description)\n".utf8))
        if case .usage = error { print(""); print(usage) }
        return error.exitCode
    } catch {
        FileHandle.standardError.write(Data("ERROR \(error)\n".utf8))
        return 3
    }
}

exit(run())
