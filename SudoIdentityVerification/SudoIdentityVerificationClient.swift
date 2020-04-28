//
// Copyright © 2020 Anonyome Labs, Inc. All rights reserved.
//
// SPDX-License-Identifier: Apache-2.0
//

import Foundation
import SudoLogging
import SudoUser
import AWSAppSync
import AWSS3
import SudoConfigManager
import SudoApiClient

/// List of possible errors thrown by `SudoIdentityVerificationClient` implementation.
///
/// - invalidConfig: Indicates that the configuration dictionary passed to initialize the client was not valid.
/// - invalidInput: Indicates that the input to the API was invalid.
/// - badData: Indicates the bad data was found in cache or in backend response.
/// - identityNotVerified: Indicates the identity could not be verified based on the input provided.
/// - notSignedIn: Indicates the user is not signed in and the API call requires the user to be signed in.
/// - verificationResultNotFound: Indicates the identity verification result cannot be found for the user.
/// - graphQLError: Indicates that a GraphQL error was returned by the backend.
/// - fatalError: Indicates that a fatal error occurred. This could be due to coding error, out-of-memory
///     condition or other conditions that is beyond control of `SudoIdentityVerificationClient` implementation.
public enum SudoIdentityVerificationClientError: Error {
    case invalidConfig
    case invalidInput
    case badData
    case identityNotVerified
    case notSignedIn
    case verificationResultNotFound
    case graphQLError(description: String)
    case fatalError(description: String)
}

/// Generic API result. The API can fail with an error or complete successfully.
///
/// - success: API completed successfully.
/// - failure: API failed with an error.
public enum ApiResult {
    case success
    case failure(cause: Error)
}

/// Result returned by API for verifying an identity. The API can fail with an
/// error or return the verified identity.
///
/// - success: The identity was verified successfully.
/// - failure: Verification failed with an error.
public enum VerificationResult {
    case success(verifiedIdentity: VerifiedIdentity)
    case failure(cause: Error)
}

/// Result returned by API for retrieving the list of supported countries for
/// identity verification. The API can fail with an error or return the list of
/// supported countries..
///
/// - success: Supported country list retrieval was successful.
/// - failure: Supported country list retrieval  failed with an error.
public enum GetSupportedCountriesResult {
    case success(countries: [String])
    case failure(cause: Error)
}

/// Options for controlling the behaviour of query APIs.
///
/// - cacheOnly: returns query result from the local cache only.
/// - remoteOnly: performs the query in the backend and ignores any cached entries.
public enum QueryOption {
    case cacheOnly
    case remoteOnly
}

/// Protocol encapsulating a set of functions for identity verification..
public protocol SudoIdentityVerificationClient: class {

    /// Retrieves the list of supported countries for identity verification.
    ///
    /// - Parameter completion: The completion handler to invoke to pass the support countries retrieval result.
    func getSupportedCountries(completion: @escaping (GetSupportedCountriesResult) -> Void)

    /// Verifies an identity against the known public records and returns a result indicating whether or not the identity
    /// details provided was verified with enough confidence to grant the user access to Sudo platform functions such
    /// as provisioning a virtual card.
    ///
    /// - Parameters:
    ///   - firstName: First name
    ///   - lastName: Last name.
    ///   - address: Address.
    ///   - city: City.
    ///   - state: State.
    ///   - postalCode: Postal code.
    ///   - country: 3 characters ISO country code. Must be one of countries retrieved via `getSupportedCountries` API.
    ///   - dateOfBirth: Date of birth formatted in "yyyy-MM-dd".
    ///   - completion: The completion handler to invoke to pass the verification result.
    func verifyIdentity(firstName: String,
                        lastName: String,
                        address: String,
                        city: String?,
                        state: String?,
                        postalCode: String,
                        country: String,
                        dateOfBirth: String,
                        completion: @escaping (VerificationResult) -> Void)

    /// Checks the identity verification status of the currently signed in user.
    ///
    /// - Parameters:
    ///   - option: Option to determine whether to check the status in the backend or return the cached result.
    ///   - completion: The completion handler to invoke to pass the verification result.
    func checkIdentityVerification(option: QueryOption, completion: @escaping (VerificationResult) -> Void)

    /// Resets any cached data.
    ///
    /// - Throws: `SudoIdentityVerificationClientError`
    func reset() throws

}

/// Default implementation of `SudoIdentityVerificationClient`.
public class DefaultSudoIdentityVerificationClient: SudoIdentityVerificationClient {

    public struct Config {

        // Configuration namespace.
        struct Namespace {
            static let identityVerificationService = "IdentityVerificationService"
        }

    }

    /// Default logger for the client.
    private let logger: Logger

    ///`SudoUserClient` instance required to issue authentication tokens and perform cryptographic operations.
    private let sudoUserClient: SudoUserClient

    /// GraphQL client for communicating with the identity verification service.
    private let graphQLClient: AWSAppSyncClient

    /// Operation queue used for serializing and rate controlling expensive remote API calls.
    private let sudoOperationQueue = SudoOperationQueue()

    /// Intializes a new `DefaultSudoIdentityVerificationClient` instance.
    ///
    /// - Parameters:
    ///   - sudoUserClient: `SudoUserClient` instance required to issue authentication tokens and perform cryptographic operations.
    ///   - logger: A logger to use for logging messages. If none provided then a default internal logger will be used.
    /// - Throws: `SudoIdentityVerificationClientError`
    convenience public init(sudoUserClient: SudoUserClient, logger: Logger? = nil) throws {
        var config: [String: Any] = [:]

        if let configManager = DefaultSudoConfigManager(),
            let identityVerificationServiceConfig = configManager.getConfigSet(namespace: Config.Namespace.identityVerificationService) {
            config[Config.Namespace.identityVerificationService] = identityVerificationServiceConfig
        }

        guard let graphQLClient = try ApiClientManager.instance?.getClient(sudoUserClient: sudoUserClient) else {
            throw SudoIdentityVerificationClientError.invalidConfig
        }

        try self.init(config: config, sudoUserClient: sudoUserClient, logger: logger, graphQLClient: graphQLClient)
    }

    /// Intializes a new `DefaultSudoIdentityVerificationClient` instance with the specified backend configuration.
    ///
    /// - Parameters:
    ///   - config: Configuration parameters for the client.
    ///   - sudoUserClient: `SudoUserClient` instance required to issue authentication tokens and perform cryptographic operations.
    ///   - logger: A logger to use for logging messages. If none provided then a default internal logger will be used.
    ///   - graphQLClient: Optional GraphQL client to use. Mainly used for unit testing.
    /// - Throws: `SudoIdentityVerificationClientError`
    public init(config: [String: Any], sudoUserClient: SudoUserClient, logger: Logger? = nil, graphQLClient: AWSAppSyncClient? = nil) throws {

        #if DEBUG
            AWSDDLog.sharedInstance.logLevel = .verbose
            AWSDDLog.add(AWSDDTTYLogger.sharedInstance)
        #endif

        let logger = logger ?? Logger.sudoIdentityVerificationClientLogger
        self.logger = logger
        self.sudoUserClient = sudoUserClient

        if let graphQLClient = graphQLClient {
            self.graphQLClient = graphQLClient
        } else {
            guard let sudoIdentityVerificationServiceConfig = config[Config.Namespace.identityVerificationService] as? [String: Any],
                let configProvider = SudoIdentityVerificationClientConfigProvider(config: sudoIdentityVerificationServiceConfig) else {
                throw SudoIdentityVerificationClientError.invalidConfig
            }

            let appSyncConfig = try AWSAppSyncClientConfiguration(appSyncServiceConfig: configProvider,
                                                                  userPoolsAuthProvider: GraphQLAuthProvider(client: self.sudoUserClient),
                                                                  urlSessionConfiguration: URLSessionConfiguration.default,
                                                                  cacheConfiguration: AWSAppSyncCacheConfiguration.inMemory,
                                                                  connectionStateChangeHandler: nil,
                                                                  s3ObjectManager: nil,
                                                                  presignedURLClient: nil,
                                                                  retryStrategy: .exponential)
            self.graphQLClient = try AWSAppSyncClient(appSyncConfig: appSyncConfig)
            self.graphQLClient.apolloClient?.cacheKeyForObject = { $0["id"] }
        }
    }

    public func getSupportedCountries(completion: @escaping (GetSupportedCountriesResult) -> Void) {
        self.logger.info("Retrieving the list of supported countries for identity verification.")

        self.graphQLClient.fetch(query: GetSupportedCountriesQuery(), cachePolicy: .fetchIgnoringCacheData) { (result, error) in
            if let error = error {
                return completion(GetSupportedCountriesResult.failure(cause: error))
            }

            guard let result = result else {
                return completion(GetSupportedCountriesResult.failure(cause: SudoIdentityVerificationClientError.fatalError(description: "Query returned nil result.")))
            }

            if let errors = result.errors {
                let message = "Query failed with errors: \(errors)"
                self.logger.error(message)
                return completion(GetSupportedCountriesResult.failure(cause: SudoIdentityVerificationClientError.graphQLError(description: message)))
            }

            guard let countryList = result.data?.getSupportedCountries?.countryList else {
                return completion(GetSupportedCountriesResult.success(countries: []))
            }

            completion(GetSupportedCountriesResult.success(countries: countryList))
        }
    }

    public func verifyIdentity(firstName: String,
                               lastName: String,
                               address: String,
                               city: String?,
                               state: String?,
                               postalCode: String,
                               country: String,
                               dateOfBirth: String,
                               completion: @escaping (VerificationResult) -> Void) {
        self.logger.info("Verifying an identity.")

        let verifyIdentityOp = VerifyIdentity(graphQLClient: self.graphQLClient, firstName: firstName, lastName: lastName, address: address, city: city, state: state, postalCode: postalCode, country: country, dateOfBirth: dateOfBirth)
        let completionOp = BlockOperation {
            if let error = verifyIdentityOp.error {
                self.logger.error("Failed verify the identity: \(error)")
                completion(VerificationResult.failure(cause: error))
            } else {
                guard let verifiedIdentity = verifyIdentityOp.verifiedIdentity else {
                    self.logger.error("The identity could not be verified.")
                    return completion(VerificationResult.failure(cause: SudoIdentityVerificationClientError.identityNotVerified))
                }

                self.logger.info("The identity verified successfully.")
                completion(VerificationResult.success(verifiedIdentity: verifiedIdentity))
            }
        }

        self.sudoOperationQueue.addOperations([verifyIdentityOp, completionOp], waitUntilFinished: false)
    }

    public func checkIdentityVerification(option: QueryOption, completion: @escaping (VerificationResult) -> Void) {
        self.logger.info("Checking the identity verification status.")

        let cachePolicy: CachePolicy
        switch option {
        case .cacheOnly:
            cachePolicy = .returnCacheDataDontFetch
        case .remoteOnly:
            cachePolicy = .fetchIgnoringCacheData
        }

        self.graphQLClient.fetch(query: CheckIdentityVerificationQuery(), cachePolicy: cachePolicy) { (result, error) in
            if let error = error {
                return completion(VerificationResult.failure(cause: error))
            }

            guard let result = result else {
                return completion(VerificationResult.failure(cause: SudoIdentityVerificationClientError.fatalError(description: "Query returned nil result.")))
            }

            if let errors = result.errors {
                let message = "Query failed with errors: \(errors)"
                self.logger.error(message)
                return completion(VerificationResult.failure(cause: SudoIdentityVerificationClientError.graphQLError(description: message)))
            }

            guard let verifiedIdentity = result.data?.checkIdentityVerification else {
                return completion(VerificationResult.failure(cause: SudoIdentityVerificationClientError.verificationResultNotFound))
            }

            var verifiedAt: Date?
            if let verifiedAtEpochMs = verifiedIdentity.verifiedAtEpochMs {
                verifiedAt = Date(millisecondsSinceEpoch: verifiedAtEpochMs)
            }

            completion(
                VerificationResult.success(verifiedIdentity: VerifiedIdentity(owner: verifiedIdentity.owner,
                                                                              verified: verifiedIdentity.verified,
                                                                              verifiedAt: verifiedAt,
                                                                              verificationMethod: verifiedIdentity.verificationMethod,
                                                                              canAttemptVerificationAgain: verifiedIdentity.canAttemptVerificationAgain,
                                                                              idScanUrl: verifiedIdentity.idScanUrl))
            )
        }
    }

    public func reset() throws {
        self.logger.info("Resetting client state.")

        try self.graphQLClient.clearCaches(options: .init(clearQueries: true, clearMutations: true, clearSubscriptions: true))
    }

}
