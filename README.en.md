- [中文](README.md)
- [English](README.en.md)


# Snell Management Script

## Introduction to the Snell Protocol  
Snell is a lightweight and efficient encrypted proxy protocol designed by the developer of **Surge**. It focuses on providing secure and fast network transmission services. With its streamlined design and robust encryption capabilities, Snell meets the demands for privacy protection and high-performance transmission. Its cross-platform compatibility and reliable performance make it a popular choice for scenarios requiring efficient proxy services, such as cross-network access, privacy protection, and encrypted data transmission.

## Introduction  
The Snell management script provides an efficient and automated solution for managing the Snell proxy service on Linux-based systems. Whether you are setting up a new Snell proxy or managing an existing instance, this script simplifies the process with commands for installation, configuration, version control, and uninstallation. It is an ideal choice for users who require a high-performance encrypted proxy service, saving time and reducing administrative complexity.

## Features  
+ Easy installation  
+ Seamless removal  
+ Configuration review  
+ Version check and upgrade  
+ One-click BBR configuration  
+ Supports both AMD64 and ARM64 architectures  

## System Requirements  
+ A Debian-based system (e.g., Ubuntu)  
+ Root or sudo access  

## Installation  
1. Download and run the script:  
```shell  
wget https://raw.githubusercontent.com/jinqians/snell.sh/main/snell.sh -O snell.sh && chmod +x snell.sh && ./snell.sh
```

## Usage  
When you run the script, you will see the following menu:  
```shell  
 =========================================  
 Author: jinqian  
 Website: https://jinqians.com  
 Description: This script is used for installing, uninstalling, reviewing, and updating the Snell proxy service.  
 =========================================  
 ============== Snell Management Tool ==============  
1) Install Snell  
2) Uninstall Snell  
3) View Snell Configuration  
4) Check for Snell Updates  
5) Update Script  
6) Install/Configure BBR  
0) Exit  
Please choose an option:  
```

## Options  
1. **Install Snell**:  
   + Installs the Snell proxy service.  
   + Automatically generates a random port and password for Snell configuration.  
   + Starts the Snell service and enables it to run at startup.  
2. **Uninstall Snell**:  
   + Stops the Snell service.  
   + Disables Snell from running at startup.  
   + Removes all Snell-related files and configurations.  
3. **View Snell Configuration**:  
   + Displays the current Snell configuration, including the IP address, port, and password.  
4. **Check for Snell Updates**:  
   + Automatically checks for the latest Snell version and provides an easy upgrade option to ensure the service remains up-to-date.  
5. **Update Script**:  
   + Updates the Snell management script to the latest version.  
6. **Install/Configure BBR**:  
   + Installs and configures the BBR network optimization module.  
0. **Exit**:  
   + Exits the script.  

## Example Output  
After installing Snell, the script will display the following configuration details:  
```shell  
Snell installation succeeded.  
CN = snell, 123.456.789.012, 54321, psk = abcdefghijklmnopqrst, version = 4, reuse = true, tfo = true  
CN = snell, ::1, 54321, psk = abcdefghijklmnopqrst, version = 4, reuse = true, tfo = true  
```  
