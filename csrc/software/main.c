int main(){

    volatile int s = 0;
    for(int i=1;i<=10;i++){
        s = s + i;
    }
    return (s==55) ?  1 : 0;
}