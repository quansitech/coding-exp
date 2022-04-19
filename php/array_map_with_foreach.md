## array_map和foreach性能对比

先说结论，foreach的性能速度比array_map快很多，根据不同的运算场景会有不同的差异。仅仅想知道结论的同学可以离开了，剩下的是具体测试证明。

另外一个结论，在这次测试中，7.4的性能比7.2要高出10倍，



通过两种测试来对比性能

PHP版本 7.4.20

1. 组装双向链

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
   $arr = [];
   for($i=0; $i < 1000000; $i++){
       array_push($arr, $i);
   }
   
   G("start");
   
   $first = true;
   $prev = null;
   $first_item = null;
   $current = null;
   
   array_map(function($item) use (&$first, &$prev, &$first_item){
       if($first){
           $first_item = new CollectionItem($item);
           $prev = $first_item;
           $first = false;
       }
       else{
           $current = new CollectionItem($item);
           $prev->setNext($current);
           $current->setPrev($prev);
           $prev = $current;
       }
   }, $arr);
   
   
   G("end");
   
   dd(G("start", "end"));
   
   //耗时 0.4628秒
   ```
   
   ```php
   $arr = [];
   for($i=0; $i < 1000000; $i++){
       array_push($arr, $i);
   }
   
   G("start");
   
   $first = true;
   $prev = null;
   $first_item = null;
   $current = null;
   
   foreach($arr as $item){
       if($first){
           $first_item = new CollectionItem($item);
           $prev = $first_item;
           $first = false;
       }
       else{
           $current = new CollectionItem($item);
           $prev->setNext($current);
           $current->setPrev($prev);
           $prev = $current;
       }
   }
   
   G("end");
   
   dd(G("start", "end"));
   
   //耗时 0.3882秒
   ```

2. 除法运算

   ```php
   $arr = [];
   for($i=0; $i < 1000000; $i++){
       array_push($arr, $i);
   }
   
   G("start");
   
   array_map(function($item){
   	$res = $item / 2;
   }, $arr);
   
   G("end");
   
   dd(G("start", "end"));
   
   //耗时 0.0562秒
   ```

   ```php
   $arr = [];
   for($i=0; $i < 1000000; $i++){
       array_push($arr, $i);
   }
   
   G("start");
   
   foreach($arr as $item){
       $res = $item / 2;
   }
   
   G("end");
   
   dd(G("start", "end"));
   
   //耗时 0.0255秒
   ```

   

总体来说foreach都要比array_map要快许多

另外测试最初是在php7.2版本进行，foreach的优势会更加明显，而且7.4比7.2的处理速度要快10倍，这点是使人更惊艳的。