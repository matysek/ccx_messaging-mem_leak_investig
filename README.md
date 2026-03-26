# CCX Memory Leak Investigation

## Overview
 
Investigation of memory leaks in CCX messaging services. Since the leak is present in all ccx-messaging services we need to investigate
what the common utilities, libraries etc are.        
 
## Suspected Root Cause        
 
### Circular References in Exception Handling         
 
Objects reference each other in a cycle that prevents garbage collection: 
 
**The Problem:**               
- Python's GC can usually handle circular references  
- Exception tracebacks create circular refs that prevent GC               
- Specific issue: `Broker → exception → __traceback__ → frame → Broker`   
 
This circular reference chain keeps objects alive indefinitely, causing the memory leak pattern observed in production.               
 
---        
 
## Testing Methodology         
 
### 1. Baseline Testing        
 
Run locally in Podman to:      
- Send large volumes of data without ephemeral environment costs          
- Benchmark the performance    
 
### 2. Local Testing Setup     
 
#### Prerequisites             
 
**Local Deployment:**          
 
1. **Optional**:                  
   ```bash 
   # Inside ingress clone directory                   
   docker build . -t ingress:latest                   
   docker-compose -f development/local-dev-start.yml up                   
   ```     
 
2. **Start local environment:**
   ```bash 
   # Inside local deploy repo
   docker compose up -d        
   ```     
 
3. **Setup archive sending script:**
   ```bash
   # Inside the mem leak repo
   python3 -m venv venv
   source venv/bin/activate

   # Install molodec from GitLab (requires dual pip indexes:
   # PyPI for build tools like hatchling, RH internal for iqe-jwt)
   PIP_INDEX_URL=https://pypi.org/simple \
   PIP_EXTRA_INDEX_URL=https://repository.engineering.redhat.com/nexus/repository/insights-qe/simple \
   pip install git+https://gitlab.cee.redhat.com/ccx/molodec.git@master

   # Install remaining dependencies
   pip install click requests
   ```     
---        
 
## Running Tests               
 
### Monitoring Memory Usage    
 
Start monitoring:         
 
```bash    
./monitor_all_local.sh         
```        

This monitors all 3 ccx-messaging based containers every 5 seconds, capturing:            
- Docker stats (CPU, memory, network I/O)             
- Python GC statistics         
- /proc/meminfo snapshots      
 
### Sending Test Archives      
 
1. **Continuous local sending (4 hours):**          
```bash    
python send_archives.py upload 
```                                   
 
## Containers Monitored        
 
1. **rules-uploader**
2. **archive-sync**
3. **rules-processing**          
             
## Files in This Repository    
 
- `send_archives.py` - Archive upload script with continuous/burst modes  
- `monitor_all_local.sh` - Comprehensive monitoring for all CCX containers
- directories with results of the monitoring as explained below

### 3. Results
- **baseline** - confirmed leak - /pre_fix_verified_leak
- **extra monitoring** (more logging, monitoring brokers) - still leaky /monitored_still_leaky
- **dr.py fix** - suspected circular references, containers run with a patch, possibly promising results, but needs more testing - /dr_py_still_leaky

Results are visualised in their directories