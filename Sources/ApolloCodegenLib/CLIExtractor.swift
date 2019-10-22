//
//  CLIExtractor.swift
//  ApolloCodegenLib
//
//  Created by Ellen Shapiro on 10/3/19.
//  Copyright © 2019 Apollo GraphQL. All rights reserved.
//

import Foundation

/// Helper for extracting and validating the node-based Apollo CLI from a zip.
struct CLIExtractor {
  
  // MARK: - Extracting the binary
  
  enum CLIExtractorError: Error, LocalizedError {
    case noBinaryFolderAfterUnzipping(atURL: URL)
    case zipFileHasInvalidSHASUM(expectedSHASUM: String, gotSHASUM: String)
    case zipFileNotPresent(atURL: URL)
    
    var errorDescription: String? {
      switch self {
      case .noBinaryFolderAfterUnzipping(let url):
        return "Some kind of error occurred with unzipping and the binary folder could not be found at \(url)"
      case .zipFileHasInvalidSHASUM(let expectedSHASUM, let gotSHASUM):
        return "Error: The SHASUM of this zip file (\(gotSHASUM)) does not match the official released version from Apollo (\(expectedSHASUM))! This may present security issues. Terminating code generation."
      case .zipFileNotPresent(let url):
        return "Could not locate file to unzip at \(url). Please make sure you're passing in the correct URL for the scripts folder!"
      }
    }
  }
  
  static let expectedSHASUM = "0845089ac6fca8a910a317fdb90f2fe486d6e50f0a5caeb6e9c779c839188798"
  
  /// Checks to see if the CLI has already been extracted and is the correct version, and extracts or re-extracts as necessary
  ///
  /// - Parameter scriptsFolderURL: The URL to the scripts folder which contains the zip file with the CLI.
  /// - Parameter expectedSHASUM: The expected SHASUM. Defaults to the real expected SHASUM. This parameter exists mostly for testing.
  /// - Returns: The URL to the binary folder of the extracted CLI.
  static func extractCLIIfNeeded(from scriptsFolderURL: URL, expectedSHASUM: String = CLIExtractor.expectedSHASUM) throws -> URL {
    let apolloFolderURL = ApolloFilePathHelper.apolloFolderURL(fromScripts: scriptsFolderURL)
    
    guard FileManager.default.apollo_folderExists(at: apolloFolderURL) else {
      CodegenLogger.log("Apollo folder doesn't exist, extracting CLI from zip file.")
      return try self.extractCLIFromZip(scriptsFolderURL: scriptsFolderURL)
    }
    
    guard try self.validateSHASUMInExtractedFile(apolloFolderURL: apolloFolderURL, expected: expectedSHASUM) else {
      CodegenLogger.log("SHASUM of extracted zip does not match expected, deleting existing folder and re-extracting.")
      try FileManager.default.apollo_deleteFolder(at: apolloFolderURL)
      return try self.extractCLIFromZip(scriptsFolderURL: scriptsFolderURL)
    }
    
    let binaryFolderURL = ApolloFilePathHelper.binaryFolderURL(fromApollo: apolloFolderURL)
    let binaryURL = ApolloFilePathHelper.binaryURL(fromBinaryFolder: binaryFolderURL)
    guard FileManager.default.apollo_fileExists(at: binaryURL) else {
      CodegenLogger.log("There was a valid `.shasum` file, but no binary at the expected path. Deleting existing apollo folder and re-extracting.", logLevel: .warning)
      try FileManager.default.apollo_deleteFolder(at: apolloFolderURL)
      return try self.extractCLIFromZip(scriptsFolderURL: scriptsFolderURL, expectedSHASUM: expectedSHASUM)
    }
    
    CodegenLogger.log("Binary already extracted!")
    return binaryFolderURL
  }
  
  /// Checks the `.shasum` file which was written out the last time the CLI
  /// was extracted to see if it matches the current version
  /// - Parameter apolloFolderURL: The URL to the extracted apollo folder.
  /// - Parameter expected: The expected SHASUM. Defaults to the real expected SHASUM. This parameter exists mostly for testing.
  /// - Returns: true if the shasums match, false if not.
  static func validateSHASUMInExtractedFile(apolloFolderURL: URL, expected: String = CLIExtractor.expectedSHASUM) throws -> Bool {
    let shasumFileURL = ApolloFilePathHelper.shasumFileURL(fromApollo: apolloFolderURL)
    guard FileManager.default.apollo_fileExists(at: shasumFileURL) else {
      return false
    }
    
    let contents = try String(contentsOf: shasumFileURL, encoding: .utf8)
    
    guard contents == expected else {
      return contents.hasPrefix(expected)
    }
    
    return true
  }
  
  /// Writes the SHASUM of the extracted version of the CLI to a file for faster checks to ensure we have the correct version.
  ///
  /// - Parameter apolloFolderURL: The URL to the extracted apollo folder.
  static func writeSHASUMToFile(apolloFolderURL: URL) throws {
    let shasumFileURL = ApolloFilePathHelper.shasumFileURL(fromApollo: apolloFolderURL)
    try CLIExtractor.expectedSHASUM.write(to: shasumFileURL,
                                          atomically: false,
                                          encoding: .utf8)
  }
  
  /// Extracts the CLI from a zip file in the scripts folder.
  ///
  /// - Parameter scriptsFolderURL: The URL to the scripts folder which contains the zip file with the CLI.
  /// - Parameter expectedSHASUM: The expected SHASUM. Defaults to the real expected SHASUM. This parameter exists mostly for testing.
  /// - Returns: The URL for the binary folder post-extraction.
  static func extractCLIFromZip(scriptsFolderURL: URL, expectedSHASUM: String = CLIExtractor.expectedSHASUM) throws -> URL {
    let zipFileURL = ApolloFilePathHelper.zipFileURL(fromScripts: scriptsFolderURL)

    try self.validateZipFileSHASUM(at: zipFileURL, expected: expectedSHASUM)
    
    CodegenLogger.log("Extracting CLI from zip file. This may take a second...")
    _ = try Basher.run(command: "tar xzf \(zipFileURL.path) -C \(scriptsFolderURL.path)", from: nil)
    
    let apolloFolderURL = ApolloFilePathHelper.apolloFolderURL(fromScripts: scriptsFolderURL)
    let binaryFolderURL = ApolloFilePathHelper.binaryFolderURL(fromApollo: apolloFolderURL)
    
    guard FileManager.default.apollo_folderExists(at: binaryFolderURL) else {
      throw CLIExtractorError.noBinaryFolderAfterUnzipping(atURL: binaryFolderURL)
    }
    
    try self.writeSHASUMToFile(apolloFolderURL: apolloFolderURL)
    
    return binaryFolderURL
  }
  
  /// Checks that the file at the given URL matches the expected SHASUM.
  ///
  /// - Parameter zipFileURL: The url to the zip file containing the Apollo CLI.
  /// - Parameter expected: The expected SHASUM. Defaults to the real expected SHASUM. This parameter exists mostly for testing.
  static func validateZipFileSHASUM(at zipFileURL: URL, expected: String = CLIExtractor.expectedSHASUM) throws {
    let shasum = try FileManager.default.apollo_shasum(at: zipFileURL)    
    guard shasum == expected else {
      throw CLIExtractorError.zipFileHasInvalidSHASUM(expectedSHASUM: expected, gotSHASUM: shasum)
    }
  }
}