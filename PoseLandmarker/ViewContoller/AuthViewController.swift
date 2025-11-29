// Copyright 2023 The MediaPipe Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import UIKit

protocol AuthViewControllerDelegate: AnyObject {
  func authViewControllerDidAuthenticate(_ viewController: AuthViewController)
}

class AuthViewController: UIViewController {
  
  weak var delegate: AuthViewControllerDelegate?
  
  private var usernameTextField: UITextField!
  private var passwordTextField: UITextField!
  private var loginButton: UIButton!
  private var registerButton: UIButton!
  private var errorLabel: UILabel!
  private var activityIndicator: UIActivityIndicatorView!
  private var titleLabel: UILabel!
  
  override func viewDidLoad() {
    super.viewDidLoad()
    setupUI()
  }
  
  private func setupUI() {
    view.backgroundColor = .systemBackground
    
    // Title Label
    titleLabel = UILabel()
    titleLabel.text = "Pose Landmarker"
    titleLabel.font = UIFont.boldSystemFont(ofSize: 28)
    titleLabel.textAlignment = .center
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    
    // Username Text Field
    usernameTextField = UITextField()
    usernameTextField.placeholder = "Username"
    usernameTextField.autocapitalizationType = .none
    usernameTextField.autocorrectionType = .no
    usernameTextField.borderStyle = .roundedRect
    usernameTextField.translatesAutoresizingMaskIntoConstraints = false
    
    // Password Text Field
    passwordTextField = UITextField()
    passwordTextField.placeholder = "Password"
    passwordTextField.isSecureTextEntry = true
    passwordTextField.borderStyle = .roundedRect
    passwordTextField.translatesAutoresizingMaskIntoConstraints = false
    
    // Login Button
    loginButton = UIButton(type: .system)
    loginButton.setTitle("Login", for: .normal)
    loginButton.backgroundColor = .systemBlue
    loginButton.setTitleColor(.white, for: .normal)
    loginButton.layer.cornerRadius = 8
    loginButton.addTarget(self, action: #selector(loginTapped), for: .touchUpInside)
    loginButton.translatesAutoresizingMaskIntoConstraints = false
    
    // Register Button
    registerButton = UIButton(type: .system)
    registerButton.setTitle("Register", for: .normal)
    registerButton.backgroundColor = .systemGreen
    registerButton.setTitleColor(.white, for: .normal)
    registerButton.layer.cornerRadius = 8
    registerButton.addTarget(self, action: #selector(registerTapped), for: .touchUpInside)
    registerButton.translatesAutoresizingMaskIntoConstraints = false
    
    // Error Label
    errorLabel = UILabel()
    errorLabel.text = ""
    errorLabel.textColor = .systemRed
    errorLabel.numberOfLines = 0
    errorLabel.textAlignment = .center
    errorLabel.translatesAutoresizingMaskIntoConstraints = false
    
    // Activity Indicator
    activityIndicator = UIActivityIndicatorView(style: .medium)
    activityIndicator.hidesWhenStopped = true
    activityIndicator.translatesAutoresizingMaskIntoConstraints = false
    
    // Add subviews
    view.addSubview(titleLabel)
    view.addSubview(usernameTextField)
    view.addSubview(passwordTextField)
    view.addSubview(loginButton)
    view.addSubview(registerButton)
    view.addSubview(errorLabel)
    view.addSubview(activityIndicator)
    
    // Layout constraints
    NSLayoutConstraint.activate([
      titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 60),
      
      usernameTextField.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      usernameTextField.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -60),
      usernameTextField.widthAnchor.constraint(equalToConstant: 280),
      usernameTextField.heightAnchor.constraint(equalToConstant: 44),
      
      passwordTextField.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      passwordTextField.topAnchor.constraint(equalTo: usernameTextField.bottomAnchor, constant: 16),
      passwordTextField.widthAnchor.constraint(equalToConstant: 280),
      passwordTextField.heightAnchor.constraint(equalToConstant: 44),
      
      loginButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      loginButton.topAnchor.constraint(equalTo: passwordTextField.bottomAnchor, constant: 24),
      loginButton.widthAnchor.constraint(equalToConstant: 280),
      loginButton.heightAnchor.constraint(equalToConstant: 44),
      
      registerButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      registerButton.topAnchor.constraint(equalTo: loginButton.bottomAnchor, constant: 16),
      registerButton.widthAnchor.constraint(equalToConstant: 280),
      registerButton.heightAnchor.constraint(equalToConstant: 44),
      
      errorLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      errorLabel.topAnchor.constraint(equalTo: registerButton.bottomAnchor, constant: 24),
      errorLabel.widthAnchor.constraint(equalToConstant: 280),
      
      activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      activityIndicator.topAnchor.constraint(equalTo: errorLabel.bottomAnchor, constant: 16)
    ])
  }
  
  @objc private func loginTapped() {
    guard let username = usernameTextField.text, !username.isEmpty,
          let password = passwordTextField.text, !password.isEmpty else {
      showError("Please enter both username and password")
      return
    }
    
    setLoading(true)
    errorLabel.text = ""
    
    UserAuthService.shared.login(username: username, password: password) { [weak self] result in
      DispatchQueue.main.async {
        self?.setLoading(false)
        switch result {
        case .success:
          self?.delegate?.authViewControllerDidAuthenticate(self!)
        case .failure(let error):
          self?.showError(error.localizedDescription)
        }
      }
    }
  }
  
  @objc private func registerTapped() {
    guard let username = usernameTextField.text, !username.isEmpty,
          let password = passwordTextField.text, !password.isEmpty else {
      showError("Please enter both username and password")
      return
    }
    
    setLoading(true)
    errorLabel.text = ""
    
    UserAuthService.shared.register(username: username, password: password) { [weak self] result in
      DispatchQueue.main.async {
        self?.setLoading(false)
        switch result {
        case .success:
          self?.delegate?.authViewControllerDidAuthenticate(self!)
        case .failure(let error):
          self?.showError(error.localizedDescription)
        }
      }
    }
  }
  
  private func setLoading(_ loading: Bool) {
    loginButton.isEnabled = !loading
    registerButton.isEnabled = !loading
    usernameTextField.isEnabled = !loading
    passwordTextField.isEnabled = !loading
    
    if loading {
      activityIndicator.startAnimating()
    } else {
      activityIndicator.stopAnimating()
    }
  }
  
  private func showError(_ message: String) {
    errorLabel.text = message
  }
}

