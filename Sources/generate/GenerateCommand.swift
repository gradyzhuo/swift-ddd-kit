//
//  Generate.swift
//  DDDKit
//
//  Created by 卓俊諺 on 2025/2/11.
//


import Foundation
import DDDEventGenerator
import ArgumentParser

enum InputType: String, Codable, ExpressibleByArgument {
    case yaml
}

extension AccessLevel: ExpressibleByArgument {
    
}

@main
struct Generate: ParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Generate swift files.",
        subcommands: [
            Event.self,
            EventMapper.self
        ])
}


extension Generate {
    enum Errors: Error {
        case outputPathMissing
        case inputFileNotFound
        case illegalInputFile
    }
    
    struct Event: ParsableCommand {
        
        @Argument(help: "The path of the event file.")
        var input: String
        
        @Option
        var inputType: InputType = .yaml
        
        @Option
        var accessLevel: AccessLevel = .public
        
        @Option(name: .shortAndLong, help: "The path of the generated swift file")
        var output: String? = nil
        
        func run() throws {
            let eventGenerator = try EventGenerator(yamlFilePath: input)
            
            guard let outputPath = output else {
                throw Errors.outputPathMissing
            }
            
            let headerGenerator = HeaderGenerator()
            
            var lines: [String] = []
            lines.append(contentsOf: headerGenerator.render())
            lines.append("import Foundation")
            lines.append("import DDDCore")
            lines.append("")
            lines.append(contentsOf: eventGenerator.render(accessLevel: accessLevel))
            
            let content = lines.joined(separator: "\n")
            try content.write(toFile: outputPath, atomically: true, encoding: .utf8)
        }
        
    }
    
    struct EventMapper: ParsableCommand {
        
        @Argument(help: "The path of the event file.")
        var input: String
        
        @Option
        var inputType: InputType = .yaml
        
        @Option
        var accessLevel: AccessLevel = .internal
        
        @Option(name: .shortAndLong, help: "The path of the generated swift file")
        var output: String? = nil
        
        func run() throws {
            let eventMapperGenerator = try EventMapperGenerator(yamlFilePath: input)
            
            guard let outputPath = output else {
                throw Errors.outputPathMissing
            }
            
            let headerGenerator = HeaderGenerator()

            var lines: [String] = []
            lines.append(contentsOf: headerGenerator.render())
            lines.append("import Foundation")
            lines.append("import DDDCore")
            lines.append("import KurrentSupport")
            lines.append("import KurrentDB")
            lines.append("")
            lines.append(contentsOf: eventMapperGenerator.render(accessLevel: accessLevel))
            
            let content = lines.joined(separator: "\n")
            try content.write(toFile: outputPath, atomically: true, encoding: .utf8)
        }
        
    }
}



//let path = "/Users/gradyzhuo/Library/Developer/Xcode/DerivedData/MyExecutable-botehvobigvwkybiephuhgxhaxcz/SourcePackages/plugins/myexecutable.output/MyExecutable/DDDEventGeneratorPlugin/Version.swift"
//
//
//try """
//    struct Version {
//        static let version = "1.2.3"
//    }
//""".write(toFile: path, atomically: true, encoding: .utf8)

//@main
//struct Main{
//    mutating func run() throws{
//        print("hello")
//    }
//}
