## 记一次PHP Segment fault的调试



引发segfault的场景：需要通过双向链作为数据结构来完成一次遍历所有组合可能性的算法，数据量至少在20万以上。

PHP版本：7.2.34

```php
class CollectionItem{

    private $item;
    private $next = null;
    private $prev = null;

    public function __construct($item){
        $this->item = $item;
    }

    public function getItem(){
        return $this->item;
    }

    public function setPrev(CollectionItem $prev){
        $this->prev = $prev;
    }

    public function setNext(CollectionItem $next){
        $this->next = $next;
    }

    public function getPrev(){
        return $this->prev;
    }

    public function getNext(){
        return $this->next;
    }

}
```

```php
class Context{

    public $first_item;

    public function pack($collection){
    	$first = true;
        $prev = null;

        array_map(function($item) use(&$first, &$prev){
            if($first){
                $this->first_item = new CollectionItem($item);
                $prev = $this->first_item;
            }
            else{
                $current = new CollectionItem($item);
                $prev->setNext($current);
                $current->setPrev($prev);
                $prev = $current;
            }
        }, $collection);
    }
}
```

```php
$arr = [];
for($i=0; $i < 1000000; $i++){
    array_push($arr, $i);
}

$c = new Context();
$c->pack($arr);
```

运行上面的代码会引发segmentfault(必须使用上面的代码结构，否则很可能引发不了，T.T)

产生segmentfault的原因有很多，可能是PHP内核代码或者PHP扩展的内存溢出或者内存指针越界。

要定位具体产生segmentfault的位置，需要使用gdb进行调试。



步骤：

1. 执行shell命令  ulimit -c unlimited

2. php test.php   (test.php 就是产生segmentfault的脚本), 此时应该在命令行看到 Segmentation fault (core dumped), 同时在当前目录可以看到一个core文件，core文件就存放了程序运行栈的信息。

3. gdb php core  然后输入 bt，展开栈信息。

   

   ![图片](https://github.com/quansitech/files/blob/master/image-gdb.png)

   从信息中可以看到 zend_gc_collect_cycles后是一堆相同内存地址的问号，可以推断是GC触发的程序错误。然后上网搜索了下相关信息，还真找到了7.2版本的GC的一个循环引用的bug，升级到7.3以上版本就可以。

   https://bugs.php.net/bug.php?id=77427



升级到7.4版本后，问题果然解决了。



#### 总结

当用php进行大量的数据处理，内存的调用，往往会很容易发生segmentation fault。如果没有掌握相关的调试方法，问题就无从下手，写出的代码也存在很大的不确定性。掌握gdb的调试方法对于解决问题还是非常有必要。

