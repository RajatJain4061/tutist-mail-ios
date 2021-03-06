//
//  APIService+AuthenticationExtension.swift
//  ProtonMail
//
//
//  Copyright (c) 2019 Proton Technologies AG
//
//  This file is part of ProtonMail.
//
//  ProtonMail is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  ProtonMail is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with ProtonMail.  If not, see <https://www.gnu.org/licenses/>.


import Foundation
import PromiseKit

/// Auth extension
extension APIService {
    func auth2fa(res: AuthResponse, password: String, twoFACode: String?, checkSalt: Bool = true, completion: @escaping AuthCompleteBlock) {

        let credential = AuthCredential(res: res)
        credential.storeInKeychain()
        
        func exec() {
            let passwordMode = res.passwordMode
            var keySalt: String?
            var privateKey: String?
            
            func done() {
                credential.update(salt: keySalt, privateKey: privateKey)
                credential.storeInKeychain()
                if passwordMode == 1 {
                    guard let keysalt : Data = keySalt?.decodeBase64() else {
                        return completion(nil, nil, .resCheck, nil, NSError.authInValidKeySalt())
                    }
                    let mpwd = PasswordUtils.getMailboxPassword(password, salt: keysalt)
                    return completion(nil, mpwd, .resCheck, nil, nil)
                } else {
                    return completion(nil, nil, .resCheck, nil, nil)
                }
            }
            
            if !res.isEncryptedToken {
                credential.trySetToken()
                let saltapi = GetKeysSalts()
                ///
                if !checkSalt {
                    done()
                } else {
                    saltapi.authCredential = credential
                    let userApi = GetUserInfoRequest()
                    userApi.authCredential = credential
                    firstly {
                        when(fulfilled: saltapi.run(), userApi.run())
                    }.done { (saltRes, userRes)  in
                        guard  let salt = saltRes.keySalt,
                            let privatekey = userRes.userInfo?.getPrivateKey(by: saltRes.keyID) else {
                                return completion(nil, nil, .resCheck, nil, NSError.authInvalidGrant())
                        }
                        keySalt = salt
                        privateKey = privatekey
                        done()
                    }.catch { err in
                        let error = err as NSError
                        if error.isInternetError() {
                            return completion(nil, nil, .resCheck, nil, NSError.internetError())
                        } else {
                            return completion(nil, nil, .resCheck, nil, NSError.authInvalidGrant())
                        }
                    }
                }
                ///
            } else {
                keySalt = res.keySalt
                privateKey = res.privateKey
                done()
            }
        }
        
        if let code = twoFACode {
            credential.trySetToken()
            let tfaapi = TwoFARequest(code: code)
            tfaapi.authCredential = credential
            firstly {
                tfaapi.run()
               // when(resolved: tfaapi.run())
            }.done { (res) in
                if let error = res.error {
                    return completion(nil, nil, .resCheck, nil, error)
                } else {
                    exec()
                }
            }.catch { err in
                let error = err as NSError
                if error.isInternetError() {
                    return completion(nil, nil, .resCheck, nil, NSError.internetError())
                } else {
                    return completion(nil, nil, .resCheck, nil, NSError.authInvalidGrant())
                }
            }
        } else {
            exec()
        }
        
        
    }
    
    
    
    func auth(_ username: String, password: String,
              twoFACode: String?, authCredential: AuthCredential?,
              checkSalt: Bool = true, completion: AuthCompleteBlock!) {
        
        var forceRetry = false
        var forceRetryVersion = 2
        func tryAuth() {
            AuthInfoRequest(username: username, authCredential: authCredential).call() { task, res, hasError in
                if hasError {
                    guard let error = res?.error else {
                        return completion(task, nil, .resCheck, nil, NSError.authInvalidGrant())
                    }
                    if error.isInternetError() {
                        return completion(task, nil, .resCheck, nil, NSError.internetError())
                    } else {
                        return completion(task, nil, .resCheck, nil, error)
                    }
                } else if res?.code == 1000 {// caculate pwd
                    guard let authVersion = res?.Version, let modulus = res?.Modulus,
                        let ephemeral = res?.ServerEphemeral, let salt = res?.Salt, let session = res?.SRPSession else {
                        return completion(task, nil, .resCheck,nil, NSError.authUnableToParseAuthInfo())
                    }
 
                    do {
                        if authVersion <= 2 && !forceRetry {
                            forceRetry = true
                            forceRetryVersion = 2
                        }

                        //init api calls
                        let hashVersion = forceRetry ? forceRetryVersion : authVersion
                        //move the error to the wrapper
                        guard let auth = try SrpAuth(hashVersion, username, password, salt, modulus, ephemeral) else {
                            return completion(task, nil, .resCheck, nil, NSError.authUnableToGeneratePwd())
                        }
                        
                        let srpClient = try auth.generateProofs(2048)
                        guard let clientEphemeral = srpClient.clientEphemeral,
                            let clientProof = srpClient.clientProof, let expectedServerProof = srpClient.expectedServerProof else {
                            return completion(task, nil, .resCheck, nil, NSError.authUnableToGenerateSRP())
                        }
                        
                        let api = AuthRequest(username: username,
                                              ephemeral: clientEphemeral,
                                              proof: clientProof,
                                              session: session,
                                              serverProof: expectedServerProof,
                                              code: twoFACode);
                        let completionWrapper: (_ task: URLSessionDataTask?, _ res: AuthResponse?, _ hasError : Bool) -> Void = { (task, res, hasError) in
                            if hasError {
                                if let error = res?.error {
                                    if error.isInternetError() {
                                        return completion(task, nil, .resCheck, nil, NSError.internetError())
                                    } else {
                                        if forceRetry && forceRetryVersion != 0 {
                                            forceRetryVersion -= 1
                                            tryAuth()
                                        } else {
                                            return completion(task, nil, .resCheck, nil, NSError.authInvalidGrant())
                                        }
                                    }
                                } else {
                                    return completion(task, nil, .resCheck, nil, NSError.authInvalidGrant())
                                }
                            } else if res?.code == 1000 {
                                guard let res = res else {
                                    return completion(task, nil, .resCheck, nil, NSError.authInvalidGrant())
                                }
                                
                                guard let serverProof : Data = res.serverProof?.decodeBase64() else {
                                    return completion(task, nil, .resCheck, nil, NSError.authServerSRPInValid())
                                }
                                
                                if api.serverProof == serverProof {
                                    let credential = AuthCredential(res: res)
                                    credential.storeInKeychain()
                                    //if 2fa enabled
                                    if res.twoFactor != 0 {
                                        return completion(task, nil, .ask2FA, res, nil)
                                    }
                                    //if 2fa disabled
                                    self.auth2fa(res: res, password: password, twoFACode: twoFACode, checkSalt: checkSalt, completion: completion)
                                } else {
                                    return completion(task, nil, .resCheck, nil, NSError.authServerSRPInValid())
                                }
                            } else {
                                return completion(task, nil, .resCheck, nil, NSError.authUnableToParseToken())
                            }
                        }
                        api.call(completionWrapper)
                    } catch let err as NSError {
                        err.upload(toAnalytics: "tryAuth()")
                        return completion(task, nil, .resCheck, nil, NSError.authUnableToParseAuthInfo())
                    }
                } else {
                    return completion(task, nil, .resCheck, nil, NSError.authUnableToParseToken())
                }
            }
        }
        tryAuth()
    }
    
    func authRefresh(_ password:String, completion: AuthRefreshComplete?) {
        if let authCredential = AuthCredential.fetchFromKeychain() {
            AuthRefreshRequest(resfresh: authCredential.refreshToken,
                               uid: authCredential.userID).call() { task, res , hasError in
                if hasError {
                    var needsRetry : Bool = false
                    if let err = res?.error {
                        err.upload(toAnalytics : AuthErrorTitle)
                        if err.code == NSURLErrorTimedOut ||
                            err.code == NSURLErrorNotConnectedToInternet ||
                            err.code == NSURLErrorCannotConnectToHost ||
                            err.code == APIErrorCode.API_offline ||
                            err.code == APIErrorCode.HTTP503 {
                            needsRetry = true
                        } else {
                            self.refreshTokenFailedCount += 1
                        }
                    }
                    
                    if self.refreshTokenFailedCount > 5 || !needsRetry {
                        PMLog.D("self.refreshTokenFailedCount == 5")
                        completion?(task, nil, NSError.authInvalidGrant())
                    } else {
                        completion?(task, nil, NSError.internetError())
                    }
                }
                else if res?.code == 1000 {
                    do {
                        authCredential.update(res, updateUID: false)
                        try authCredential.setupToken(password)
                        authCredential.storeInKeychain()
                        
                        PMLog.D("\(authCredential.description)")
                        
                        self.refreshTokenFailedCount = 0
                    } catch let ex as NSError {
                        PMLog.D(any: ex)
                    }
                    DispatchQueue.main.async {
                        completion?(task, authCredential, nil)
                    }
                }
                else {
                    completion?(task, nil, NSError.authUnableToParseToken())
                }
            }
        } else {
            completion?(nil, nil, NSError.authCredentialInvalid())
        }
        
    }
}


