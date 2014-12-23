###Overview
Using the latest available image for SharePoint in the azure gallery, it will create a highly available SharePoint farm. Active directory infrastructure should already have been deployed. It requires the existence of a SQL Server Availability Group to which the SharePoint databases will be added.

###Virtual Machines (VMs)

1. The number of app server VMs in the farm is controlled by the input parameter 'AppServerCount'.
2. The number of web server VMs in the farm is controlled by the input parameter 'WebServerCount'.

###SharePoint Details

1. Central Admin - `http://<SharepointCloudService>.cloudapp.net:20000`
2. Default Website - `http://<SharepointCloudService>.cloudapp.net`
NOTE: Use the farm admin credentials (provided at the time of deployment) for authentication.

###Limitations
Following are the limitations of this template. Users can fork this repository and customize the template to fix them or wait for our periodic updates.
> - The template does not allow selection of a image for the SharePoint VM.
> - The template adds just a single data disk of 40 GB to the SharePoint VMs.

###References
> - [SharePoint 2013 on Azure](http://msdn.microsoft.com/en-us/library/dn275958.aspx)
> - [SharePoint 2013 and SQL Server AlwaysOn](http://blogs.msdn.com/b/sambetts/archive/2013/04/24/sharepoint-2013-and-sql-server-alwayson-high-availability-sharepoint.aspx)

