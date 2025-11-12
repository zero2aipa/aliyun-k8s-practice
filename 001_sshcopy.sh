for h in 192.168.92.11 192.168.92.12 192.168.92.10; do
  ssh-copy-id $h 
done

for h in 192.168.92.11 192.168.92.12 192.168.92.10; do  ssh $h hostname ; done
