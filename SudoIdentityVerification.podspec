Pod::Spec.new do |spec|
  spec.name                  = 'SudoIdentityVerification'
  spec.version               = '4.7.1'
  spec.author                = { 'Sudo Platform Engineering' => 'sudoplatform-engineering@anonyome.com' }
  spec.homepage              = 'https://sudoplatform.com/'
  spec.summary               = 'Identity Verification SDK for the Sudo Platform by Anonyome Labs.'
  spec.license               = { :type => 'Apache License, Version 2.0',  :file => 'LICENSE' }
  spec.source                = { :git => 'https://github.com/sudoplatform/sudo-identity-verification-ios.git', :tag => "v#{spec.version}" }
  spec.source_files          = 'SudoIdentityVerification/*.swift'
  spec.ios.deployment_target = '11.0'
  spec.requires_arc          = true
  spec.swift_version         = '5.0'

  spec.dependency 'AWSAppSync', '~> 3.0'
  spec.dependency 'SudoLogging', '~> 0.2'
  spec.dependency 'SudoUser', '~> 7.8'
  spec.dependency 'SudoApiClient', '~> 1.3'
  spec.dependency 'SudoConfigManager', '~> 1.2'
end
