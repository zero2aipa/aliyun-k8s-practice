for h in 172.18.208.11 172.18.208.12 172.18.208.13; do
  ssh-copy-id $h 
done

for h in 172.18.208.11 172.18.208.12 172.18.208.13; do  ssh $h hostname ; done