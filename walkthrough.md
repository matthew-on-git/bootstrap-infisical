Here's the walkthrough for the Infisical UI:                                                                                             
                                                                                                                                           
  1. Create a Project                                                                                                                      
  - From the dashboard, click Add New Project                                                                                              
  - Name it something like infrastructure (this will hold OPNsense secrets and any other infra secrets)                                    
  - The default "Development" environment is fine to start                                                                                 
                                                                                                                                           
  2. Create a Machine Identity                                                                                                             
  - Go to Organization Settings (gear icon, top-right) > Machine Identities                                                                
  - Click Create Identity                                                                                                                  
  - Name: ansible                                                                                                                          
  - Role: Member (you can scope it down later)                                                                                             
  - Click Create                                                                                                                           
                                                                                                                                           
  3. Add Universal Auth                                                                                                                    
  - Click on the ansible identity you just created                                                                                         
  - Under Authentication, click Add Auth Method                                                                                            
  - Select Universal Auth                                                                                                                  
  - Leave the defaults (no IP restrictions needed unless you want to lock it to specific hosts)                                            
  - Click Save                                                                                                                             
  - Copy the Client ID and Client Secret — the secret is only shown once                                                                   
                                                                                                                                           
  4. Assign Identity to the Project                                                                                                        
  - Go back to your infrastructure project                                                                                                 
  - Go to Project Settings > Access Control                                                                                                
  - Click Add Identity                                                                                                                     
  - Select the ansible identity                                                                                                            
  - Role: Viewer (read-only access to secrets is all Ansible needs)                                                                        
  - Click Add                                                                                                                              
                                                                                                                                           
  Once you have the Client ID and Client Secret, we can move on to step 3 — storing the OPNsense API credentials in Infisical and          
  scaffolding the Ansible project. Let me know when you're through these steps.  