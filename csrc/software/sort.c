#define EXIT  (*(volatile unsigned int *)0x00030000)
#define PRINT (*(volatile unsigned int *)0x00030004)

/* 断言：失败时打印出错的行号，然后立刻退出 */
#define CHECK(cond)  do { if (!(cond)) { PRINT = __LINE__; EXIT = 0; } } while (0)


int a[10] = {3,6,1,8,7,9,5,4,2,0};

// 排
void merge(int* arr1, int* arr2, int num1, int num2) {
    int p1 = 0, p2 = 0, p3 = 0;
    int buffer[num1 + num2]; 

    // 比较
    while (p1 < num1 && p2 < num2) {

        if (arr1[p1] <= arr2[p2]) { 
            buffer[p3++] = arr1[p1++];
        } 
        else {
            buffer[p3++] = arr2[p2++];
        }
    }

    // 放剩余部分
    while (p1 < num1) buffer[p3++] = arr1[p1++];
    while (p2 < num2) buffer[p3++] = arr2[p2++];

    //从buffer中拷贝进入arr
    for (int i = 0; i < num1 + num2; i++) {
        arr1[i] = buffer[i];
    }
}

// 分
void divide(int num,int* arr){
    if(num <= 1)
        return;
    else{
        int middle = num/2;
        divide(middle,arr);
        divide(num-middle,arr+middle);
        merge(arr,arr+middle,middle,num-middle);
        return;
    }
}


int main(){
    int result = 1;

    PRINT = a[0];
    PRINT = a[1];
    PRINT = a[2];
    PRINT = a[3];
    PRINT = a[4];
    PRINT = a[5];
    PRINT = a[6];
    PRINT = a[7];
    PRINT = a[8];
    PRINT = a[9];
    
    divide(10, a);
    CHECK(a[0] <= a[1]);
    CHECK(a[1] <= a[2]);
    CHECK(a[2] <= a[3]);
    CHECK(a[3] <= a[4]);
    CHECK(a[4] <= a[5]);
    CHECK(a[5] <= a[6]);
    CHECK(a[6] <= a[7]);
    CHECK(a[7] <= a[8]);
    CHECK(a[8] <= a[9]);
    
    PRINT = a[0];
    PRINT = a[1];
    PRINT = a[2];
    PRINT = a[3];
    PRINT = a[4];
    PRINT = a[5];
    PRINT = a[6];
    PRINT = a[7];
    PRINT = a[8];
    PRINT = a[9];

    EXIT = 1;
    return result;
}