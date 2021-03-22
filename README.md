# DriverManagement
This repo is for the way I am automatically managing Dell drivers for SCCM. I also included my rendition of the Driver Automation script for applying drivers to computers during OSD.

Prerequisites:
--ConfigMgr WebService
https://msendpointmgr.com/configmgr-webservice/

This webservice is the backbone of getting any existing driver packages from ConfigMgr, whether you are updating existing drivers, adding new drivers, or finding the right package for applying drivers for these scripts. I take no credit for the Webservice, that belong totally to the guys overs at msendpointmgr.com; Maurice, Nikolaj, and Jan.

The script that I have here is also based on their process for dynamically applying drivers. All I did was strip it down to the base stuff needed to apply drivers based on Model instead of trying to find it on other methods and then using the model as a fallback. I found that when I was doing this, it was inconsistent in finding the right driver model based on board identification and it wasn't falling back to model. This, for me, was just easier and more consistent.

--Configuration Manager Admin Console installed on machine that you will set the scheduled task on when automating getting drivers from Dell


I have to tell you that using this script for creating the driver packs, takes time and storage. It will automatically create the packages based on using them later for other script for the driver automation. I marked some spots in the script that will need to be changed to match your environment.

    Update-DellDriverPacks.ps1
    --Line 3 -- location of where to download the Dell Cab file that contains the list of models with all the driver download locations for use later.
    --Line 4 -- URL of the ConfigMgr Webservice
    --Line 5 -- Secret key of ConfigMgr Webservice
    --Line 9 -- Location to download driver packs to for extraction
    --Line 10 -- Base path to store the extracted files to for driver package creation
    --Line 11 -- Log File Name if you want to change it from the default one I created
    --Line 25 -- Base Path of location to store the log file for this script
    --Line 138 -- Site Code for your site
    --Line 139 -- Site Server FQDN
    --Lines 193-195 -- These lines are there because I am adding a step to copy any additional drivers over that are needed for every package, like a driver for a particular dongle
    --Line 216 -- This line needs to have the UNC base path to the driver files that were extracted for creating the package
    --Line 223 -- On this line I move the driver package from the root folder into a subfolder in ConfigMgr. This needs have the path to the folder you would want to move the driver package to or it can be eliminated if you want to move them manually or not at all
    --Line 227 -- Make sure you put the group name of the Distibution Point group you wish to automatically distibute the driver packs to
    --Line 233 -- This line needs to have the UNC base path to the driver files that were extracted for creating the package
    

Notes:
1. On line 154, I am excluding one particular model because I found in my testing that the download link in the XML for this model was wrong and would just error out, so I am skipping it.

